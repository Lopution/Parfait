import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/next_page_parser.dart';

IllustEntity entity(int id, {bool bookmarked = false}) => IllustEntity(
      id: id,
      title: 'title-$id',
      type: IllustType.illust,
      imageUrls: const IllustImageUrls(
        squareMedium: 'https://i.pximg.net/s.png',
        medium: 'https://i.pximg.net/m.png',
        large: 'https://i.pximg.net/l.png',
      ),
      caption: '',
      user: const IllustUser(
        id: 1,
        name: 'author',
        account: 'author',
        profileImageUrl: null,
      ),
      tags: const [],
      pageCount: 1,
      width: 100,
      height: 200,
      xRestrict: 0,
      aiType: 0,
      isBookmarked: bookmarked,
      totalView: 10,
      totalBookmarks: 5,
    );

void main() {
  group('IllustStore', () {
    test('merges entities keyed by ID without duplicates', () {
      final store = IllustStore();
      store.mergeAll([entity(1), entity(2)]);
      store.mergeAll([entity(2, bookmarked: true), entity(3)]);

      final all = store.getAll([1, 2, 3, 4]);
      expect(all.map((e) => e.id), [1, 2, 3]);
      expect(store.get(2)!.isBookmarked, isTrue,
          reason: 'bookmarked state must not regress');
    });

    test('updateBookmark applies changes and clear resets everything', () {
      final store = IllustStore();
      store.mergeAll([entity(1)]);
      store.updateBookmark(1, true);
      expect(store.get(1)!.isBookmarked, isTrue);
      store.clear();
      expect(store.get(1), isNull);
    });

    test('entity parser maps badges and tolerates optional fields', () {
      final parsed = IllustEntity.fromJson({
        'id': 7,
        'title': 'R18 AI multi-page ugoira',
        'type': 'ugoira',
        'image_urls': {
          'square_medium': 'https://i.pximg.net/s.png',
          'medium': 'https://i.pximg.net/m.png',
          'large': 'https://i.pximg.net/l.png',
        },
        'user': {
          'id': 5,
          'name': 'author',
          'account': 'author',
          'profile_image_urls': {'medium': 'https://i.pximg.net/p.png'},
        },
        'tags': [
          {'name': 'original'},
          {'name': 'タグ', 'translated_name': 'tag'},
        ],
        'page_count': 3,
        'width': 800,
        'height': 600,
        'x_restrict': 1,
        'illust_ai_type': 2,
        'is_bookmarked': true,
      });
      expect(parsed.isR18, isTrue);
      expect(parsed.isAi, isTrue);
      expect(parsed.isUgoira, isTrue);
      expect(parsed.pageCount, 3);
      expect(parsed.tags, hasLength(2));
      expect(parsed.tags[1].translatedName, 'tag');

      expect(
        () => IllustEntity.fromJson({'title': 'no id'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('PagedFeedController (via RecommendedIllustController behaviour)', () {
    test('page parse errors surface as ApiParseError, not empty success', () {
      expect(
        () => IllustEntity.parsePage({'illusts': [{'id': 'not-int'}]}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => IllustEntity.parsePage({'no-illusts': []}),
        throwsA(isA<FormatException>()),
      );
      final ok = IllustEntity.parsePage({
        'illusts': [
          {
            'id': 1,
            'title': 't',
            'image_urls': {
              'square_medium': 'a',
              'medium': 'b',
              'large': 'c',
            },
            'user': {'id': 1, 'name': 'n', 'account': 'a'},
          }
        ],
        'next_url': null,
      });
      expect(ok.illusts, hasLength(1));
      expect(ok.nextUrl, isNull);
    });
  });

  group('feed dedupe semantics (documented via store)', () {
    test('cross-page duplicate IDs collapse in the store', () {
      final store = IllustStore();
      final page1 = [entity(1), entity(2), entity(3)];
      final page2 = [entity(2, bookmarked: true), entity(3), entity(4)];
      store.mergeAll(page1);
      store.mergeAll(page2);
      expect(store.getAll([1, 2, 3, 4]), hasLength(4));
    });

    test('a cursor may not move the client off the Pixiv API origin', () {
      for (final bad in [
        'http://app-api.pixiv.net/v1/illust/recommended?offset=30',
        'https://evil.example.com/v1/illust/recommended?offset=30',
        'https://app-api.pixiv.net@evil.example.com/v1/illust/recommended',
      ]) {
        expect(
          () => NextPageParser.parse(bad),
          throwsA(isA<NextPageParseError>()),
          reason: bad,
        );
      }
    });
  });
}
