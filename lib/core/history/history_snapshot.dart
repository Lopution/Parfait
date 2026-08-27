import '../entity/illust_entity.dart';
import '../novel/novel_entity.dart';
import 'history_models.dart';

HistorySnapshot snapshotFromIllust(IllustEntity entity) {
  return HistorySnapshot(
    title: entity.title,
    authorName: entity.user.name,
    authorId: entity.user.id,
    coverUrl: entity.imageUrls.medium,
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
  );
}
