import '../entity/illust_entity.dart';
import '../novel/novel_entity.dart';

/// Pure C9 content-rating predicate shared by discovery feeds and the
/// desktop widget. No UI, network or settings side effects: callers pass
/// the resolved booleans.
///
/// Tag/user/work blocking is owned by `core/mute` (MuteStore +
/// `muteHitFor`), not this predicate — the legacy `blocked_tags` pref is
/// migrated into the mute set on hydrate.
bool isLocallyBlocked(
  IllustEntity entity, {
  required bool blockR18,
  required bool blockAI,
}) => _blocked(entity.xRestrict, entity.isAi, blockR18, blockAI);

/// [isLocallyBlocked] for a novel: `x_restrict` and `novel_ai_type`.
bool isNovelLocallyBlocked(
  NovelEntity novel, {
  required bool blockR18,
  required bool blockAI,
}) => _blocked(novel.xRestrict, novel.novelAiType == 2, blockR18, blockAI);

/// The R-18 block covers R-18G (x_restrict 2) as well, as the ranking
/// categories it hides do (PAGE-15).
bool _blocked(int xRestrict, bool ai, bool blockR18, bool blockAI) =>
    (blockR18 && xRestrict > 0) || (blockAI && ai);
