import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/app/image_tier_cache.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';

void main() {
  test('upgrade serves a cached higher tier for a lower request', () {
    const key = '1_0';
    expect(IllustTierCache.resolve(key, IllustImageTier.medium, 'm.jpg'), (
      'm.jpg',
      IllustImageTier.medium,
    ));
    IllustTierCache.record(key, IllustImageTier.large, 'l.jpg');
    expect(IllustTierCache.resolve(key, IllustImageTier.medium, 'm.jpg'), (
      'l.jpg',
      IllustImageTier.large,
    ));
    IllustTierCache.record(key, IllustImageTier.original, 'o.jpg');
    expect(IllustTierCache.resolve(key, IllustImageTier.medium, 'm.jpg'), (
      'o.jpg',
      IllustImageTier.original,
    ));
  });

  test(
    'never downgrades: cached lower tier does not serve a higher request',
    () {
      const key = '2_0';
      IllustTierCache.record(key, IllustImageTier.medium, 'm.jpg');
      expect(IllustTierCache.resolve(key, IllustImageTier.original, 'o.jpg'), (
        'o.jpg',
        IllustImageTier.original,
      ));
    },
  );

  test('bestBelow serves the highest cached tier under the request', () {
    const key = '3_0';
    expect(IllustTierCache.bestBelow(key, IllustImageTier.original), isNull);
    IllustTierCache.record(key, IllustImageTier.medium, 'm.jpg');
    expect(IllustTierCache.bestBelow(key, IllustImageTier.original), 'm.jpg');
    IllustTierCache.record(key, IllustImageTier.large, 'l.jpg');
    expect(IllustTierCache.bestBelow(key, IllustImageTier.original), 'l.jpg');
    // Never equal or above the requested tier, and never below itself.
    expect(IllustTierCache.bestBelow(key, IllustImageTier.large), 'm.jpg');
    expect(IllustTierCache.bestBelow(key, IllustImageTier.medium), isNull);
  });

  test('mediumUrlAt resolves per-page medium urls', () {
    const entity = IllustEntity(
      id: 9,
      title: 't',
      type: IllustType.illust,
      imageUrls: IllustImageUrls(
        squareMedium: 's.jpg',
        medium: 'm0.jpg',
        large: 'l0.jpg',
      ),
      caption: '',
      user: IllustUser(id: 1, name: 'u', account: 'u', profileImageUrl: null),
      tags: [],
      pageCount: 2,
      width: 100,
      height: 100,
      xRestrict: 0,
      aiType: 0,
      isBookmarked: false,
      totalView: 0,
      totalBookmarks: 0,
      metaPages: [
        IllustImageUrls(
          squareMedium: 's1.jpg',
          medium: 'm1.jpg',
          large: 'l1.jpg',
          original: 'o1.jpg',
        ),
        IllustImageUrls(
          squareMedium: 's2.jpg',
          medium: 'm2.jpg',
          large: 'l2.jpg',
          original: 'o2.jpg',
        ),
      ],
    );
    expect(entity.mediumUrlAt(0), 'm1.jpg');
    expect(entity.mediumUrlAt(1), 'm2.jpg');
    // Out-of-range on a multi-page work falls back to the work-level tier.
    expect(entity.mediumUrlAt(9), 'm0.jpg');
  });

  test('imageTierOf maps entity urls', () {
    const entity = IllustEntity(
      id: 7,
      title: 't',
      type: IllustType.illust,
      imageUrls: IllustImageUrls(
        squareMedium: 's.jpg',
        medium: 'm.jpg',
        large: 'l.jpg',
        original: 'o.jpg',
      ),
      caption: '',
      user: IllustUser(id: 1, name: 'u', account: 'u', profileImageUrl: null),
      tags: [],
      pageCount: 1,
      width: 100,
      height: 100,
      xRestrict: 0,
      aiType: 0,
      isBookmarked: false,
      totalView: 0,
      totalBookmarks: 0,
    );
    expect(entity.imageTierOf('m.jpg'), IllustImageTier.medium);
    expect(entity.imageTierOf('l.jpg'), IllustImageTier.large);
    expect(entity.imageTierOf('o.jpg'), IllustImageTier.original);
    expect(entity.imageTierOf('s.jpg'), isNull);
    expect(entity.imageTierOf('other.jpg'), isNull);
    expect(entity.imageTierKeyAt(3), '7_3');
  });
}
