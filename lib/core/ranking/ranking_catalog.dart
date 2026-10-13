import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../illust/ranking_repository.dart';
import '../novel/novel_repository.dart';
import '../settings/app_settings.dart';
import '../settings/arrangement.dart';
import '../settings/settings_controller.dart';
import 'ranking_category.dart';

/// One kind of ranking, illust or novel, as its page, the category sheet
/// and the settings entry see it: the modes, their default arrangement, and
/// where the user's arrangement and last category are kept.
final class RankingCatalog<M extends RankingCategory> {
  RankingCatalog._({
    required this.defaults,
    required this.fallback,
    required M? Function(String apiValue) fromApiValue,
    required List<ArrangedEntry>? Function(AppSettings) saved,
    required String? Function(AppSettings) lastViewed,
    required Future<void> Function(SettingsController, List<ArrangedEntry>?)
    writeArrangement,
    required Future<void> Function(SettingsController, String) writeLastViewed,
  }) : _fromApiValue = fromApiValue,
       _saved = saved,
       _lastViewed = lastViewed,
       _writeArrangement = writeArrangement,
       _writeLastViewed = writeLastViewed;

  final Arrangement<M> defaults;

  /// An all-ages category shown when the local block hides every other.
  final M fallback;

  final M? Function(String apiValue) _fromApiValue;
  final List<ArrangedEntry>? Function(AppSettings) _saved;
  final String? Function(AppSettings) _lastViewed;
  final Future<void> Function(SettingsController, List<ArrangedEntry>?)
  _writeArrangement;
  final Future<void> Function(SettingsController, String) _writeLastViewed;

  /// The user's arrangement; the default until settings have loaded.
  late final Provider<Arrangement<M>> arrangementProvider = Provider((ref) {
    final saved = ref.watch(
      settingsProvider.select((async) => switch (async.value) {
        final settings? => _saved(settings),
        null => null,
      }),
    );
    return Arrangement.resolve(defaults, saved, _fromApiValue);
  });

  late final Provider<M?> lastViewedProvider = Provider((ref) {
    final apiValue = ref.watch(
      settingsProvider.select((async) => switch (async.value) {
        final settings? => _lastViewed(settings),
        null => null,
      }),
    );
    return apiValue == null ? null : _fromApiValue(apiValue);
  });

  /// Saves [arrangement]; the default one is saved as null, so a later
  /// version's new default reaches a user who never edited.
  Future<void> saveArrangement(
    SettingsController settings,
    Arrangement<M> arrangement,
  ) => _writeArrangement(
    settings,
    arrangement == defaults
        ? null
        : arrangement.toEntries((mode) => mode.apiValue),
  );

  Future<void> saveLastViewed(SettingsController settings, M mode) =>
      _writeLastViewed(settings, mode.apiValue);
}

final illustRankingCatalog = RankingCatalog<RankingMode>._(
  defaults: RankingMode.defaultArrangement,
  fallback: RankingMode.day,
  fromApiValue: RankingMode.fromApiValue,
  saved: (settings) => settings.illustRankingArrangement,
  lastViewed: (settings) => settings.illustRankingLastMode,
  writeArrangement: (settings, entries) =>
      settings.setIllustRankingArrangement(entries),
  writeLastViewed: (settings, apiValue) =>
      settings.setIllustRankingLastMode(apiValue),
);

final novelRankingCatalog = RankingCatalog<NovelRankingMode>._(
  defaults: NovelRankingMode.defaultArrangement,
  fallback: NovelRankingMode.day,
  fromApiValue: NovelRankingMode.fromApiValue,
  saved: (settings) => settings.novelRankingArrangement,
  lastViewed: (settings) => settings.novelRankingLastMode,
  writeArrangement: (settings, entries) =>
      settings.setNovelRankingArrangement(entries),
  writeLastViewed: (settings, apiValue) =>
      settings.setNovelRankingLastMode(apiValue),
);

/// The browse settings' local block, as the ranking categories read it.
final rankingBlockProvider = Provider<({bool r18, bool ai})>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => (
        r18: async.value?.enableLocalBlockR18 ?? false,
        ai: async.value?.enableLocalBlockAI ?? false,
      ),
    ),
  );
});
