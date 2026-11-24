import '../entity/illust_entity.dart';
import '../novel/novel_entity.dart';
import 'history_models.dart';

/// Flattens original and translated tag names into compact newline-delimited
/// text for local history search, deduplicating case-insensitively.
String? formatHistoryTagsText(
  Iterable<({String name, String? translatedName})> tags,
) {
  final kept = <String>[];
  final seen = <String>{};
  void add(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    if (seen.add(trimmed.toLowerCase())) kept.add(trimmed);
  }

  for (final tag in tags) {
    add(tag.name);
    add(tag.translatedName);
  }
  return kept.isEmpty ? null : kept.join('\n');
}

HistorySnapshot snapshotFromIllust(IllustEntity entity) {
  return HistorySnapshot(
    title: entity.title,
    authorName: entity.user.name,
    authorId: entity.user.id,
    coverUrl: entity.imageUrls.medium,
    tagsText: formatHistoryTagsText([
      for (final tag in entity.tags)
        (name: tag.name, translatedName: tag.translatedName),
    ]),
  );
}

HistorySnapshot snapshotFromNovel(
  NovelEntity entity, {
  String? anchorParagraphId,
  int? anchorOffset,
}) {
  return HistorySnapshot(
    title: entity.title,
    authorName: entity.user.name,
    authorId: entity.user.id,
    coverUrl: entity.coverImageUrl,
    contentVersion: entity.contentVersion,
    anchorParagraphId: anchorParagraphId,
    anchorOffset: anchorOffset,
    tagsText: formatHistoryTagsText([
      for (final tag in entity.tags)
        (name: tag.name, translatedName: tag.translatedName),
    ]),
  );
}
