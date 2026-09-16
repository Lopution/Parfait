import '../entity/illust_entity.dart';

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
}) {
  if (blockR18 && entity.isR18) return true;
  if (blockAI && entity.isAi) return true;
  return false;
}
