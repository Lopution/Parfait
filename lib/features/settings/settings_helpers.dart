import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/layout/content_widths.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/download/download_destination.dart';
import '../../core/download/naming_rule.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

String settingsText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

/// The settings column cap (D1): on wide surfaces the page body is centered
/// at [ContentWidths.settings]; below the cap the constraint is a no-op, so
/// there is no breakpoint branch.
Widget settingsNarrowBody(Widget child) => Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: ContentWidths.settings),
    child: child,
  ),
);

/// Wraps an immediate settings write: failures surface as a snackbar and the
/// controller keeps the old value (SettingsController._writeTail rolls back).
/// [failureMessageKey] selects the failure text; defaults to the generic
/// `settingsWriteFailed`.
Future<bool> persistSettings(
  BuildContext context,
  Future<void> Function() action, {
  String? failureMessageKey,
}) async {
  try {
    await action();
    return true;
  } on Object catch (error) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        '${settingsText(context, failureMessageKey ?? 'settingsWriteFailed')}: '
        '$error',
      );
    }
    return false;
  }
}

Widget settingsUnavailable(
  BuildContext context,
  WidgetRef ref,
  AsyncValue<AppSettings> state, {
  required String titleKey,
}) {
  return Scaffold(
    appBar: AppBar(title: Text(settingsText(context, titleKey))),
    body: state.when(
      loading: () => const FeedLoading(),
      error: (error, _) => SettingsLoadError(
        error: error,
        onRetry: () => ref.read(settingsProvider.notifier).reload(),
      ),
      // AsyncData<AppSettings> is never null; this branch only keeps the
      // helper total if the provider implementation changes later.
      data: (_) => const SizedBox.shrink(),
    ),
  );
}

void openSettingsPage(BuildContext context, String path) {
  context.push<void>(path);
}

/// Supported app languages as (native display name, BCP-47 tag) pairs —
/// the language page lists them and the settings root reuses the table
/// for the current-value summary. Native names are locale-independent
/// on purpose: the picker must be readable in any UI language.
const List<(String, String)> languageItems = [
  ('简体中文', 'zh-CN'),
  ('English', 'en-US'),
  ('日本語', 'ja-JP'),
  ('Русский', 'ru-RU'),
];

/// Native display name for [tag]; falls back to the raw tag so an
/// unexpected persisted value stays visible instead of blanking out.
String languageDisplayName(String tag) {
  for (final (name, itemTag) in languageItems) {
    if (itemTag == tag) return name;
  }
  return tag;
}

String themeModeLabel(BuildContext context, int themeCode) {
  return switch (themeCode) {
    AppSettings.darkTheme => context.l10n.dark,
    AppSettings.lightTheme => context.l10n.light,
    _ => context.l10n.system,
  };
}

String imageSourceLabel(BuildContext context, ImageSourceMode mode) {
  return switch (mode) {
    ImageSourceMode.auto => context.l10n.imageSourceAuto,
    ImageSourceMode.normal => context.l10n.imageSourceNormal,
    ImageSourceMode.pixivCat => context.l10n.imageSourcePixivCat,
    ImageSourceMode.pixivRe => context.l10n.imageSourcePixivRe,
    ImageSourceMode.pixivNl => context.l10n.imageSourcePixivNl,
    ImageSourceMode.custom => context.l10n.imageSourceCustom,
  };
}

String networkModeLabel(BuildContext context, NetworkMode mode) {
  return switch (mode) {
    NetworkMode.automatic => context.l10n.networkModeAutomatic,
    NetworkMode.compatPrefer => context.l10n.networkModeCompatPrefer,
    NetworkMode.directOnly => context.l10n.networkModeDirectOnly,
  };
}

String translationProviderLabel(
  BuildContext context,
  TranslationProvider provider,
) {
  return switch (provider) {
    TranslationProvider.disabled => context.l10n.translateDisabled,
    TranslationProvider.baidu => context.l10n.translateBaidu,
    TranslationProvider.translationLlm => context.l10n.translateLlm,
    TranslationProvider.google => context.l10n.translateGoogle,
  };
}

String namingPresetLabel(BuildContext context, NamingPreset preset) {
  return switch (preset) {
    NamingPreset.id => context.l10n.namingPresetId,
    NamingPreset.artistTitleId => context.l10n.namingPresetArtistTitleId,
    NamingPreset.titleId => context.l10n.namingPresetTitleId,
    NamingPreset.custom => context.l10n.namingPresetCustom,
  };
}

String downloadDestinationLabel(
  BuildContext context,
  DownloadDestination destination,
) {
  return switch (destination.kind) {
    DownloadDestinationKind.pixivAlbum => context.l10n.saveLocationPixivAlbum,
    DownloadDestinationKind.customAlbum =>
      '${context.l10n.saveLocationCustomAlbum} '
          '(${destination.customAlbumName})',
    DownloadDestinationKind.safFolder => context.l10n.saveLocationSafFolder,
  };
}
