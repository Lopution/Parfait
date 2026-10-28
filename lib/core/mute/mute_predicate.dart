import '../entity/illust_entity.dart';
import '../novel/novel_entity.dart';
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
  final author = entity.user;
  return _authorOrTagHit(
    (author.id, author.name),
    entity.tags.map((tag) => tag.name),
    state,
  );
}

/// [muteHitFor] for a novel: its author or a tag. Work mutes hold illust
/// ids, so they never match a novel.
MuteHit? novelMuteHitFor(NovelEntity novel, MuteState state) => _authorOrTagHit(
  (novel.user.id, novel.user.name),
  novel.tags.map((tag) => tag.name),
  state,
);

MuteHit? _authorOrTagHit(
  (int, String) author,
  Iterable<String> tags,
  MuteState state,
) {
  final (authorId, authorName) = author;
  final mutedUser = state.users[authorId];
  if (mutedUser != null) {
    return MuteHit(
      kind: MuteKind.user,
      label: mutedUser.name.isEmpty ? authorName : mutedUser.name,
    );
  }
  for (final tag in tags) {
    if (state.isTagMuted(tag)) return MuteHit(kind: MuteKind.tag, label: tag);
  }
  return null;
}
