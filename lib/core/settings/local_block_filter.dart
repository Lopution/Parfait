import '../entity/illust_entity.dart';

/// Pure C9 local-blocking predicate shared by discovery feeds and the
/// desktop widget. No UI, network or settings side effects: callers pass the
/// resolved booleans and the blocked tag set.
///
/// One hit hides the work: R18 switch, AI switch, or any intersection with
/// the blocked tag set.
bool isLocallyBlocked(
  IllustEntity entity, {
  required bool blockR18,
  required bool blockAI,
  required Set<String> blockedTags,
}) {
  if (blockR18 && entity.isR18) return true;
  if (blockAI && entity.isAi) return true;
  if (blockedTags.isEmpty) return false;
  for (final tag in entity.tags) {
    if (blockedTags.contains(tag.name)) return true;
  }
  return false;
}
