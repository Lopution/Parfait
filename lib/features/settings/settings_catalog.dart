import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../../app/widgets/settings/settings_anchor.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/lookup.dart';
import 'settings_helpers.dart' show languageItems;

/// The settings pages the search can open. Each one's row on its parent
/// page (the settings index for the top level) is anchored at it and
/// takes its title from it, so the row and the page cannot disagree.
enum SettingsPageRef implements SettingsEntry {
  account('/settings/account', 'accountManagement'),
  theme('/settings/theme', 'themeSettings'),
  language('/settings/language', 'languageSettings'),
  translate('/settings/translate', 'translateSettings'),
  motion('/settings/motion', 'motionSettings'),
  browse('/settings/browse', 'browseSettings'),
  muted('/settings/muted', 'mutedItemsSettings'),
  network('/settings/network', 'networkSettings'),
  networkProbe(
    '/settings/network/probe',
    'networkProbeTitle',
    parent: SettingsPageRef.network,
  ),
  networkAdvanced(
    '/settings/network/advanced',
    'networkAdvanced',
    parent: SettingsPageRef.network,
  ),
  download('/settings/download', 'downloadSettings'),
  downloadDestination(
    '/settings/download/destination',
    'saveLocation',
    parent: SettingsPageRef.download,
  ),
  backup('/settings/backup', 'backupSettings'),
  about('/settings/about', 'aboutSettings'),

  /// A diagnostics page behind the developer unlock: anchored like the
  /// others but never offered by the search.
  frameProbe('/settings/frame-probe', 'frameProbeTitle', indexed: false);

  const SettingsPageRef(
    this.path,
    this.titleKey, {
    this.parent,
    this.indexed = true,
  });

  final String path;
  final String titleKey;

  /// The page its row is on; null for the settings index.
  final SettingsPageRef? parent;
  final bool indexed;

  @override
  String get id => 'page.$name';

  @override
  String title(AppLocalizations l10n) => l10nLookup(l10n, titleKey);
}

/// Every setting the search can find, with the page it lives on. The
/// settings rows take their entry as `setting:` and their title from it;
/// this enum is the whole index, so a new setting is added here and
/// nowhere else.
///
/// A choice group lists its options, and a block whose rows only exist in
/// some states (a credential row under its provider, the server settings
/// once they load) is anchored as a group whose [extraKeys] name those
/// rows.
enum Setting implements SettingsEntry {
  accountTransferExport(SettingsPageRef.account, 'accountTransferExportTitle'),
  serverDisplay(
    SettingsPageRef.account,
    'serverDisplaySettings',
    extraKeys: ['serverShowAi', 'serverRestrictedMode'],
  ),
  themeMode(
    SettingsPageRef.theme,
    null,
    optionKeys: ['system', 'light', 'dark'],
  ),
  followSystemColors(SettingsPageRef.theme, 'followSystemColors'),
  appLanguage(SettingsPageRef.language, null),
  translationProvider(
    SettingsPageRef.translate,
    null,
    optionKeys: [
      'translateDisabled',
      'translateBaidu',
      'translateLlm',
      'translateGoogle',
    ],
    extraKeys: ['translateBaiduCredential', 'translateLlmCredential'],
  ),
  pageTransition(
    SettingsPageRef.motion,
    'motionPageTransition',
    optionKeys: [
      'pageTransitionStyleSystem',
      'pageTransitionStyleSharedAxis',
      'pageTransitionStyleZoom',
      'pageTransitionStyleSlide',
    ],
  ),
  animationSpeed(
    SettingsPageRef.motion,
    'animationSpeed',
    optionKeys: [
      'animationSpeedFast',
      'animationSpeedNormal',
      'animationSpeedSlow',
    ],
  ),
  reduceMotion(SettingsPageRef.motion, 'reduceMotion'),
  pressFeedback(SettingsPageRef.motion, 'pressFeedback'),
  hapticStrength(
    SettingsPageRef.motion,
    'hapticStrength',
    optionKeys: [
      'hapticStrengthOff',
      'hapticStrengthLight',
      'hapticStrengthStandard',
      'hapticStrengthStrong',
    ],
  ),
  blockR18(SettingsPageRef.browse, 'blockR18'),
  blockAI(SettingsPageRef.browse, 'blockAI'),
  hideMuted(SettingsPageRef.browse, 'hideMuted'),
  previewQuality(
    SettingsPageRef.browse,
    'previewQuality',
    optionKeys: ['qualityMedium', 'qualityLarge'],
  ),
  detailQuality(
    SettingsPageRef.browse,
    'detailQuality',
    optionKeys: ['qualityLarge', 'qualityOriginal'],
  ),
  viewQuality(
    SettingsPageRef.browse,
    'viewQuality',
    optionKeys: ['qualityLarge', 'qualityOriginal'],
  ),
  mutedTags(SettingsPageRef.muted, 'mutedTagsSection'),
  mutedUsers(SettingsPageRef.muted, 'mutedUsersSection'),
  mutedWorks(SettingsPageRef.muted, 'mutedWorksSection'),
  networkMode(
    SettingsPageRef.network,
    'networkModeListTitle',
    optionKeys: [
      'networkModeAutomatic',
      'networkModeCompatPrefer',
      'networkModeDirectOnly',
    ],
  ),
  imageSource(
    SettingsPageRef.network,
    'imageSource',
    optionKeys: [
      'imageSourceAuto',
      'imageSourceNormal',
      'imageSourcePixivCat',
      'imageSourcePixivRe',
      'imageSourcePixivNl',
      'imageSourceCustom',
    ],
  ),
  networkThirdParty(SettingsPageRef.network, 'networkThirdParty'),
  networkEffectiveRoutes(SettingsPageRef.network, 'networkEffectiveRoutes'),
  dohEndpoints(SettingsPageRef.networkAdvanced, 'networkDohEndpoints'),
  echFrontHost(SettingsPageRef.networkAdvanced, 'networkEchFrontHost'),
  networkAdvancedReset(SettingsPageRef.networkAdvanced, 'networkAdvancedReset'),
  maxDownloadCount(SettingsPageRef.download, 'maxDownloadCount'),
  downloadCaption(SettingsPageRef.download, 'downloadCaption'),
  namingPreset(
    SettingsPageRef.download,
    'namingPreset',
    optionKeys: [
      'namingPresetId',
      'namingPresetArtistTitleId',
      'namingPresetTitleId',
      'namingPresetCustom',
    ],
    extraKeys: ['namingTemplate'],
  ),
  saveLocationAlbum(
    SettingsPageRef.downloadDestination,
    'saveLocationAlbum',
    extraKeys: ['saveLocationCustomAlbum'],
  ),
  saveLocationSafFolder(
    SettingsPageRef.downloadDestination,
    'saveLocationSafFolder',
  ),
  backupExport(SettingsPageRef.backup, 'backupExport'),
  backupImport(SettingsPageRef.backup, 'backupImport'),
  aboutVersion(SettingsPageRef.about, 'aboutVersion'),
  aboutLicense(SettingsPageRef.about, 'aboutLicense'),
  aboutAttribution(SettingsPageRef.about, 'aboutAttribution'),
  aboutSource(SettingsPageRef.about, 'aboutSource'),
  aboutExportLogs(SettingsPageRef.about, 'aboutExportLogs'),
  aboutDisplayRefreshRate(SettingsPageRef.about, 'aboutDisplayRefreshRate'),
  aboutCheckUpdate(SettingsPageRef.about, 'aboutCheckUpdate');

  const Setting(
    this.page,
    this.titleKey, {
    this.optionKeys = const [],
    this.extraKeys = const [],
  });

  final SettingsPageRef page;

  /// Null for a choice group shown without a title.
  final String? titleKey;
  final List<String> optionKeys;

  /// Rows of the block that only exist in some states.
  final List<String> extraKeys;

  /// Whether the setting exists on this platform; the page shows the row
  /// under the same condition.
  bool get available => switch (this) {
    hapticStrength => defaultTargetPlatform == TargetPlatform.android,
    aboutDisplayRefreshRate => !kIsWeb && Platform.isAndroid,
    _ => true,
  };

  @override
  String get id => name;

  /// The link that opens the setting's page with it revealed.
  String get location =>
      Uri(path: page.path, queryParameters: {focusQuery: id}).toString();

  @override
  String? title(AppLocalizations l10n) {
    final key = titleKey;
    return key == null ? null : l10nLookup(l10n, key);
  }

  /// The option labels as the page shows them.
  List<String> options(AppLocalizations l10n) => switch (this) {
    // Language names are written in their own language on purpose.
    appLanguage => [for (final (name, _) in languageItems) name],
    _ => [for (final key in optionKeys) l10nLookup(l10n, key)],
  };

  List<String> extras(AppLocalizations l10n) => [
    for (final key in extraKeys) l10nLookup(l10n, key),
  ];
}

/// The page of all settings, with their search.
const settingsIndexPath = '/settings/all';

/// The query parameter of a settings route naming the entry to reveal.
const focusQuery = 'focus';

/// One search hit: the [entry], the text that matched and where it lives.
@immutable
class SettingsSearchResult {
  const SettingsSearchResult({
    required this.entry,
    required this.label,
    required this.location,
    required this.path,
  });

  final SettingsEntry entry;

  /// The matched text: the title, or the option or row that matched.
  final String label;

  /// Route that opens it.
  final String location;

  /// Where it is, for the result's second line: page names, and the
  /// setting's own title when an option matched.
  final List<String> path;
}

/// Settings and pages whose text contains [query] in [l10n]'s language,
/// case- and space-insensitively. Title hits come first, prefix hits
/// before the rest; ties keep catalog order.
List<SettingsSearchResult> searchSettings(AppLocalizations l10n, String query) {
  final needle = _normalize(query);
  if (needle.isEmpty) return const [];
  final ranked = <(int, SettingsSearchResult)>[];

  int? titleRank(String text) {
    final haystack = _normalize(text);
    if (haystack.startsWith(needle)) return 0;
    if (haystack.contains(needle)) return 1;
    return null;
  }

  List<String> pathOf(SettingsPageRef? page) => [
    for (var p = page; p != null; p = p.parent) p.title(l10n),
  ].reversed.toList();

  for (final page in SettingsPageRef.values) {
    if (!page.indexed) continue;
    final title = page.title(l10n);
    final rank = titleRank(title);
    if (rank == null) continue;
    ranked.add((
      rank,
      SettingsSearchResult(
        entry: page,
        label: title,
        location: page.path,
        path: pathOf(page.parent),
      ),
    ));
  }

  for (final setting in Setting.values) {
    if (!setting.available) continue;
    final title = setting.title(l10n);
    final rank = title == null ? null : titleRank(title);
    if (rank != null) {
      ranked.add((
        rank,
        SettingsSearchResult(
          entry: setting,
          label: title!,
          location: setting.location,
          path: pathOf(setting.page),
        ),
      ));
      continue;
    }
    final other = [
      ...setting.options(l10n),
      ...setting.extras(l10n),
    ].where((text) => _normalize(text).contains(needle)).firstOrNull;
    if (other == null) continue;
    ranked.add((
      2,
      SettingsSearchResult(
        entry: setting,
        label: other,
        location: setting.location,
        path: [...pathOf(setting.page), ?title],
      ),
    ));
  }

  // List.sort is not stable; the index keeps catalog order within a rank.
  final indexed = ranked.indexed.toList()
    ..sort((a, b) {
      final byRank = a.$2.$1.compareTo(b.$2.$1);
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return [for (final (_, (_, result)) in indexed) result];
}

String _normalize(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'\s+'), '');
