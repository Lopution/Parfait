import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/widgets/feed/illust_card_layout.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/settings/app_settings.dart';

import 'helpers/illust_fixtures.dart';

IllustEntity _work(int width, int height, {String? squareMedium}) {
  final json = illustJson(1, width: width, height: height);
  if (squareMedium != null) {
    (json['image_urls'] as Map<String, dynamic>)['square_medium'] =
        squareMedium;
  }
  return parseIllust(json);
}

/// pixiv's own square thumbnail, under its size directory.
const _ownSquare = 'img-master/img/2024/01/02/03/04/05/123_p0_square1200.jpg';

IllustCardPreview _preview(
  IllustEntity entity,
  int cardPhysicalWidth, {
  PreviewQuality quality = PreviewQuality.medium,
}) => illustCardPreview(
  entity,
  quality: quality,
  cardPhysicalWidth: cardPhysicalWidth,
);

void main() {
  group('illustCardPreview', () {
    test('a work up to 1:2 keeps its ratio and the user tier', () {
      for (final cardWidth in [500, 680, 1000]) {
        for (final (width, height) in [(800, 600), (800, 1200), (600, 1200)]) {
          final work = _work(width, height);
          final medium = _preview(work, cardWidth);
          expect(medium.crop, IllustCardCrop.none);
          expect(medium.heightRatio, height / width);
          expect(medium.url, work.imageUrls.medium);
          expect(medium.tier, IllustImageTier.medium);

          final large = _preview(
            work,
            cardWidth,
            quality: PreviewQuality.large,
          );
          expect(large.url, work.imageUrls.large);
          expect(large.tier, IllustImageTier.large);
        }
      }
    });

    test('a taller work crops large or switches to the square thumbnail', () {
      // (width, height) → expected crop per card width 500 / 680 / 1000.
      // large is fitted into 600×1200: a 1:2.5 work gets 480 px of width,
      // a 1:3 work 400 px. The crop holds while that is ≥ 80% of the card.
      final table = <(int, int), List<IllustCardCrop>>{
        (1000, 2500): [
          IllustCardCrop.top, // 480 ≥ 400
          IllustCardCrop.square, // 480 < 544
          IllustCardCrop.square,
        ],
        (2000, 6000): [
          IllustCardCrop.top, // 400 ≥ 400
          IllustCardCrop.square,
          IllustCardCrop.square,
        ],
        (1000, 8000): [
          IllustCardCrop.square, // 150 < 400
          IllustCardCrop.square,
          IllustCardCrop.square,
        ],
      };
      for (final MapEntry(key: (width, height), value: crops)
          in table.entries) {
        final work = _work(width, height);
        for (final (i, cardWidth) in [500, 680, 1000].indexed) {
          final preview = _preview(work, cardWidth);
          final reason = '${width}x$height on a $cardWidth px card';
          expect(preview.crop, crops[i], reason: reason);
          switch (preview.crop) {
            case IllustCardCrop.top:
              expect(preview.heightRatio, 2.0, reason: reason);
              expect(preview.url, work.imageUrls.large, reason: reason);
              expect(preview.tier, IllustImageTier.large, reason: reason);
            case IllustCardCrop.square || IllustCardCrop.topSquare:
              expect(preview.heightRatio, 1.0, reason: reason);
              expect(
                preview.url,
                squarePreviewUrl(work.imageUrls.squareMedium, cardWidth),
                reason: reason,
              );
              expect(preview.tier, isNull, reason: reason);
            case IllustCardCrop.none:
              fail('$reason should not keep its full ratio');
          }
        }
      }
    });

    test('a narrow original bounds the large width', () {
      // 1:3 again, but the original is only 300 px wide: large cannot be
      // wider than that, below the 400 px a 500 px card needs.
      expect(_preview(_work(300, 900), 500).crop, IllustCardCrop.square);
      expect(_preview(_work(2000, 6000), 500).crop, IllustCardCrop.top);
    });

    test(
      "pixiv's own square thumbnail is the work's top, an author's is not",
      () {
        for (final (squareMedium, crop) in [
          (
            'https://i.pximg.net/c/360x360_70/$_ownSquare',
            IllustCardCrop.topSquare,
          ),
          (
            'https://i.pximg.net/c/360x360_70/custom-thumb/img/2024/01/02/03/04/'
                '05/123_p0_custom1200.jpg',
            IllustCardCrop.square,
          ),
        ]) {
          final preview = _preview(
            _work(1000, 8000, squareMedium: squareMedium),
            500,
          );
          expect(preview.crop, crop, reason: squareMedium);
          expect(preview.url, squarePreviewUrl(squareMedium, 500));
        }
      },
    );

    test('unknown dimensions read as a square, uncropped card', () {
      final preview = _preview(_work(0, 0), 500);
      expect(preview.crop, IllustCardCrop.none);
      expect(preview.heightRatio, 1.0);
    });
  });

  group('squarePreviewUrl', () {
    const path = _ownSquare;
    const squareMedium = 'https://i.pximg.net/c/360x360_70/$path';

    test('a card takes the 540 resize up to 540 px, square1200 past it, on '
        'its own host; other shapes stay square_medium', () {
      final expected = {
        (squareMedium, 540): 'https://i.pximg.net/c/540x540_70/$path',
        (squareMedium, 320): 'https://i.pximg.net/c/540x540_70/$path',
        (squareMedium, 541): 'https://i.pximg.net/$path',
        ('https://i.pixiv.re/c/360x360_70/$path', 500):
            'https://i.pixiv.re/c/540x540_70/$path',
        for (final url in [
          'https://i.pximg.net/1/square.jpg',
          'https://i.pximg.net/c/360x360_70/custom-thumb/x.jpg',
          'not a url %',
        ])
          (url, 500): url,
      };
      for (final MapEntry(key: (url, width), value: preview)
          in expected.entries) {
        expect(squarePreviewUrl(url, width), preview, reason: '$url at $width');
      }
    });

    test("isTopSquareThumbnail knows pixiv's own square at any size", () {
      for (final url in [
        'https://i.pximg.net/c/360x360_70/$path',
        'https://i.pximg.net/c/540x540_70/$path',
        'https://i.pximg.net/$path',
      ]) {
        expect(isTopSquareThumbnail(url), isTrue, reason: url);
      }
      for (final url in [
        'https://i.pximg.net/c/360x360_70/custom-thumb/img/2024/01/02/03/04/'
            '05/123_p0_custom1200.jpg',
        'https://i.pximg.net/c/540x540_70/img-master/img/2024/01/02/03/04/05/'
            '123_p0_master1200.jpg',
        'https://i.pximg.net/1/square.jpg',
        'not a url %',
      ]) {
        expect(isTopSquareThumbnail(url), isFalse, reason: url);
      }
    });
  });
}
