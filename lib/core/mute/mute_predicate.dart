import '../entity/illust_entity.dart';
import 'mute_models.dart';

/// Why a work is muted. [label] is the human-readable hit (tag name,
/// author name, or work title) for the reveal affordance and management UI.
class MuteHit {
  const MuteHit({required this.kind, required this.label});

  final MuteKind kind;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is MuteHit && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(kind, label);
}

/// Pure effective-mute predicate. Work wins over user wins over tag so the
/// most specific reason surfaces first. No side effects — callers pass the
/// resolved [MuteState].
MuteHit? muteHitFor(IllustEntity entity, MuteState state) {
  if (state.isWorkMuted(entity.id)) {
    return MuteHit(kind: MuteKind.work, label: entity.title);
  }
  final mutedUser = state.users[entity.user.id];
  if (mutedUser != null) {
    return MuteHit(
      kind: MuteKind.user,
      label: mutedUser.name.isEmpty ? entity.user.name : mutedUser.name,
    );
  }
  for (final tag in entity.tags) {
    if (state.isTagMuted(tag.name)) {
      return MuteHit(kind: MuteKind.tag, label: tag.name);
    }
  }
  return null;
}
