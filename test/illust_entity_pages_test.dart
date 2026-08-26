import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';

import 'helpers/illust_fixtures.dart';

void main() {
  group('IllustEntity page payloads (detail R2/R3/R4)', () {
    test('meta_pages parse into per-page URLs', () {
      final entity = parseIllust(
        illustJson(7, pageCount: 3, withMetaPages: true),
      );
      expect(entity.pageCount, 3);
      expect(entity.metaPages, hasLength(3));
      expect(entity.originalUrlAt(0), 'https://i.pximg.net/7/p0/original.jpg');
      expect(entity.originalUrlAt(2), 'https://i.pximg.net/7/p2/original.jpg');
      expect(entity.originalUrlAt(3), isNull,
          reason: 'index beyond pageCount has no URL');
      expect(entity.viewerUrls(), [
        'https://i.pximg.net/7/p0/original.jpg',
        'https://i.pximg.net/7/p1/original.jpg',
        'https://i.pximg.net/7/p2/original.jpg',
      ]);
    });

    test('single page prefers meta_single_page original', () {
      final entity = parseIllust(
        illustJson(8, withMetaSinglePage: true),
      );
      expect(entity.originalUrlAt(0), 'https://i.pximg.net/8/single_original.jpg');
      expect(entity.viewerUrls(),
          ['https://i.pximg.net/8/single_original.jpg']);
    });

    test('feed-shaped entity falls back to image_urls.original', () {
      final entity = parseIllust(illustJson(9));
      expect(entity.originalUrlAt(0), 'https://i.pximg.net/9/original.jpg');
      expect(entity.visible, isTrue);
    });

    test('visible false parses for restricted works', () {
      final entity = parseIllust(illustJson(10, visible: false));
      expect(entity.visible, isFalse);
    });
  });

  group('IllustStore merge non-regression (detail AC)', () {
    test('feed refresh after detail does not strip page URLs', () {
      final store = IllustStore();
      final detail = parseIllust(
        illustJson(1, pageCount: 2, withMetaPages: true, bookmarked: true),
      );
      store.mergeAll([detail]);

      // Feed refresh carries the same work without page payloads and with
      // an older bookmark snapshot.
      final feedItem = parseIllust(illustJson(1, bookmarked: false));
      store.mergeAll([feedItem]);

      final merged = store.get(1)!;
      expect(merged.metaPages, hasLength(2),
          reason: 'detail page URLs must survive a feed refresh');
      expect(merged.originalUrlAt(1), 'https://i.pximg.net/1/p1/original.jpg');
      expect(merged.isBookmarked, isTrue,
          reason: 'bookmark state never regresses');
    });

    test('restricted state sticks once observed', () {
      final store = IllustStore();
      store.mergeAll([parseIllust(illustJson(2, visible: false))]);
      store.mergeAll([parseIllust(illustJson(2, visible: true))]);
      expect(store.get(2)!.visible, isFalse);
    });

    test('detail refresh wins fields but keeps newer bookmark', () {
      final store = IllustStore();
      store.mergeAll([parseIllust(illustJson(3, bookmarked: false))]);
      store.mergeAll([
        parseIllust(
          illustJson(3, bookmarked: true, withMetaSinglePage: true),
        ),
      ]);
      final merged = store.get(3)!;
      expect(merged.metaSinglePageOriginalUrl,
          'https://i.pximg.net/3/single_original.jpg');
      expect(merged.isBookmarked, isTrue);
    });
  });
}
