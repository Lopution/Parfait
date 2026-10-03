import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/haptics/app_haptics.dart';
import '../../../app/haptics/haptics_driver.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../app/widgets/settings/settings_choice_tile.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_group_content.dart';
import '../../../core/network/compat/network_contracts.dart';
import '../../../core/network/compat/network_providers.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';
import '../../../app/widgets/app_segmented_button.dart';

class BrowseSettingsPage extends ConsumerStatefulWidget {
  const BrowseSettingsPage({super.key});

  @override
  ConsumerState<BrowseSettingsPage> createState() => _BrowseSettingsPageState();
}

class _BrowseSettingsPageState extends ConsumerState<BrowseSettingsPage> {
  late final TextEditingController _customController;
  late final FocusNode _customFocusNode;
  bool _customDirty = false;
  bool _testingMirror = false;

  static const _presets = [
    ImageSourceMode.auto,
    ImageSourceMode.normal,
    ImageSourceMode.pixivCat,
    ImageSourceMode.pixivRe,
    ImageSourceMode.pixivNl,
  ];

  @override
  void initState() {
    super.initState();
    _customController = TextEditingController();
    _customFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _customController.dispose();
    _customFocusNode.dispose();
    super.dispose();
  }

  Future<bool> _selectSource(String source) {
    return persistSettings(
      context,
      () => ref.read(settingsProvider.notifier).selectImageSource(source),
    );
  }

  /// Returns the normalized custom prefix after validating, persisting and
  /// selecting it — or null when the input cannot be a safe https origin.
  /// The destination registry only trusts the *active* selection, so the
  /// candidate must be stored before the policy can route a probe to it.
  Future<String?> _applyCustomInput() async {
    final normalized = ImageMirror.normalizeCustomSource(
      _customController.text,
    );
    if (normalized == null) {
      showAppSnackBar(context, context.l10n.imageSourceCustomInvalid);
      return null;
    }
    final saved = await _selectSource(normalized);
    if (!saved || !mounted) return null;
    setState(() => _customDirty = false);
    return normalized;
  }

  Future<void> _saveCustomSource() async {
    final normalized = await _applyCustomInput();
    if (normalized != null && mounted) {
      showAppSnackBar(context, context.l10n.saved);
    }
  }

  /// Connectivity check through the real image pipeline: the just-selected
  /// mirror host is allowlisted on the rebuilt policy, and the request runs
  /// the same resolver/route/client pool as on-screen image loads. Any HTTP
  /// response — including an error status — proves the origin answered.
  Future<void> _testMirror() async {
    final normalized = await _applyCustomInput();
    if (normalized == null) return;
    setState(() => _testingMirror = true);
    try {
      final client = ref
          .read(pixivNetworkFactoryProvider)
          .client(PixivDestinationPurpose.image);
      final response = await client
          .get(Uri.parse(normalized))
          .timeout(const Duration(seconds: 10));
      if (mounted) {
        showAppSnackBar(
          context,
          context.l10n.imageSourceTestOk('${response.statusCode}'),
        );
      }
    } on NetworkRedirectException catch (error) {
      if (mounted) {
        // The returned status code is the probe's expected output, not raw
        // error text — a redirect answer still describes a reachable host.
        final statusCode = error.statusCode;
        showAppSnackBar(context, context.l10n.imageSourceTestOk('$statusCode'));
      }
    } on Object catch (error) {
      if (mounted) {
        showErrorSnackBar(
          context,
          action: context.l10n.imageSourceTestFailed,
          error: error,
        );
      }
    } finally {
      if (mounted) setState(() => _testingMirror = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
    final customSource = settings.customImageSource ?? '';
    if (!_customDirty && _customController.text != customSource) {
      _customController.text = customSource;
    }
    final isCustom = settings.imageSourceMode == ImageSourceMode.custom;
    final autoWinner = ref.watch(autoImageSourceWinnerProvider);
    return guardDraft(
      dirty: _customDirty,
      child: Scaffold(
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
                      () => ref
                          .read(settingsProvider.notifier)
                          .setHideMuted(value),
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                title: Text(context.l10n.previewQuality),
                children: [
                  SettingsGroupContent(
                    child: AppSegmentedButton<PreviewQuality>(
                      segments: [
                        for (final quality in PreviewQuality.values)
                          ButtonSegment<PreviewQuality>(
                            value: quality,
                            label: Text(_qualityText(context, quality)),
                          ),
                      ],
                      selected: {settings.previewQuality},
                      onSelectionChanged: (selected) => persistSettings(
                        context,
                        () => ref
                            .read(settingsProvider.notifier)
                            .setPreviewQuality(selected.first),
                      ),
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                title: Text(context.l10n.detailQuality),
                children: [
                  SettingsGroupContent(
                    child: AppSegmentedButton<DetailQuality>(
                      segments: [
                        for (final quality in const [
                          DetailQuality.large,
                          DetailQuality.original,
                        ])
                          ButtonSegment<DetailQuality>(
                            value: quality,
                            label: Text(_qualityText(context, quality)),
                          ),
                      ],
                      selected: {settings.detailQuality},
                      onSelectionChanged: (selected) => persistSettings(
                        context,
                        () => ref
                            .read(settingsProvider.notifier)
                            .setDetailQuality(selected.first),
                      ),
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                title: Text(context.l10n.viewQuality),
                children: [
                  SettingsGroupContent(
                    child: AppSegmentedButton<ViewQuality>(
                      segments: [
                        for (final quality in const [
                          ViewQuality.large,
                          ViewQuality.original,
                        ])
                          ButtonSegment<ViewQuality>(
                            value: quality,
                            label: Text(_qualityText(context, quality)),
                          ),
                      ],
                      selected: {settings.viewQuality},
                      onSelectionChanged: (selected) => persistSettings(
                        context,
                        () => ref
                            .read(settingsProvider.notifier)
                            .setViewQuality(selected.first),
                      ),
                    ),
                  ),
                ],
              ),
              // Android-only: other platforms keep the fixed 300ms slide —
              // the tier picker would be a dead control there.
              if (defaultTargetPlatform == TargetPlatform.android)
                SettingsGroup(
                  title: Text(context.l10n.pageTransitionSpeed),
                  footer: settings.reduceMotion
                      ? Text(context.l10n.pageTransitionSpeedReduceHint)
                      : null,
                  children: [
                    SettingsGroupContent(
                      child: AppSegmentedButton<PageTransitionSpeed>(
                        segments: [
                          for (final speed in PageTransitionSpeed.values)
                            ButtonSegment<PageTransitionSpeed>(
                              value: speed,
                              label: Text(
                                '${_pageTransitionSpeedText(context, speed)}'
                                ' · ${speed.code}ms',
                              ),
                            ),
                        ],
                        selected: {settings.pageTransitionSpeed},
                        // Greyed out while reduce motion is on: the gate
                        // collapses every transition to zero, so the tier
                        // has nothing to drive (footnote explains why).
                        onSelectionChanged: settings.reduceMotion
                            ? null
                            : (selected) => persistSettings(
                                context,
                                () => ref
                                    .read(settingsProvider.notifier)
                                    .setPageTransitionSpeed(selected.first),
                              ),
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
                ],
              ),
              // Android-only: the haptics driver is a no-op elsewhere.
              if (defaultTargetPlatform == TargetPlatform.android)
                _HapticStrengthGroup(selected: settings.hapticStrength),
              SettingsGroup(
                title: Text(context.l10n.imageSource),
                children: [
                  for (final mode in _presets)
                    SettingsChoiceTile(
                      title: Text(imageSourceLabel(context, mode)),
                      subtitle: switch (mode) {
                        ImageSourceMode.pixivCat => Text(
                          context.l10n.imageSourceUnreachableMainland,
                        ),
                        ImageSourceMode.auto => Text(
                          autoWinner == null
                              ? context.l10n.imageSourceAutoPending
                              : context.l10n.imageSourceAutoWinner(autoWinner),
                        ),
                        _ => null,
                      },
                      selected: settings.imageSource == mode.host,
                      onTap: () => _selectSource(mode.host),
                    ),
                  SettingsChoiceTile(
                    title: Text(context.l10n.imageSourceCustom),
                    subtitle: Text(
                      settings.customImageSource ??
                          context.l10n.imageSourceCustomUnset,
                    ),
                    selected: isCustom,
                    onTap: () {
                      final saved = settings.customImageSource;
                      if (saved != null) {
                        _selectSource(saved);
                      } else {
                        _customFocusNode.requestFocus();
                      }
                    },
                  ),
                  SettingsGroupContent(
                    child: TextField(
                      controller: _customController,
                      focusNode: _customFocusNode,
                      decoration: InputDecoration(
                        labelText: context.l10n.imageSourceCustom,
                        helperText: context.l10n.imageSourceCustomHint,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() => _customDirty = true),
                    ),
                  ),
                  SettingsGroupContent(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: _testingMirror
                                ? null
                                : _saveCustomSource,
                            child: Text(context.l10n.save),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _testingMirror ? null : _testMirror,
                            icon: _testingMirror
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.network_check, size: 18),
                            label: Text(context.l10n.imageSourceApplyAndTest),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
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
      title: Text(l10n.hapticStrength),
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
        SettingsGroupContent(
          child: AppSegmentedButton<HapticStrength>(
            segments: [
              for (final strength in HapticStrength.values)
                ButtonSegment<HapticStrength>(
                  value: strength,
                  label: Text(_hapticStrengthText(context, strength)),
                ),
            ],
            selected: {selected},
            // Four segments on a phone-width row: the check icon would
            // squeeze the labels, and the fill already marks the level.
            showSelectedIcon: false,
            // The preview below is this picker's haptic.
            haptics: false,
            onSelectionChanged: (picked) {
              AppHaptics.preview(picked.first);
              persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .setHapticStrength(picked.first),
              );
            },
          ),
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

String _pageTransitionSpeedText(BuildContext context, PageTransitionSpeed s) {
  return switch (s) {
    PageTransitionSpeed.fast => context.l10n.pageTransitionFast,
    PageTransitionSpeed.normal => context.l10n.pageTransitionNormal,
    PageTransitionSpeed.slow => context.l10n.pageTransitionSlow,
  };
}

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
