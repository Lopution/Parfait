import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/next_page_parser.dart';

IllustEntity entity(
  int id, {
  bool bookmarked = false,
  String? createDate,
  String caption = '',
  List<IllustTag> tags = const [],
  bool visible = true,
  int pageCount = 1,
}) => IllustEntity(
  id: id,
  title: 'title-$id',
  type: IllustType.illust,
  imageUrls: const IllustImageUrls(
    squareMedium: 'https://i.pximg.net/s.png',
    medium: 'https://i.pximg.net/m.png',
    large: 'https://i.pximg.net/l.png',
  ),
  caption: caption,
  user: const IllustUser(
    id: 1,
    name: 'author',
    account: 'author',
    profileImageUrl: null,
  ),
  tags: tags,
  pageCount: pageCount,
  width: 100,
  height: 200,
  xRestrict: 0,
  aiType: 0,
  isBookmarked: bookmarked,
  totalView: 10,
  totalBookmarks: 5,
  visible: visible,
  createDate: createDate,
);

IllustEntity _richSparseTarget() => entity(
  1,
  bookmarked: true,
  caption: 'detail caption',
  tags: const [IllustTag(name: 'original')],
  pageCount: 4,
);

IllustEntity _emptyAuthoritative() =>
    entity(1, caption: '', tags: const [], visible: false, pageCount: 1);

void main() {
  group('IllustStore', () {
    test('merges entities keyed by ID without duplicates', () {
      final store = IllustStore();
      store.mergeAll([entity(1), entity(2)]);
      store.mergeAll([entity(2, bookmarked: true), entity(3)]);

      final all = store.getAll([1, 2, 3, 4]);
      expect(all.map((e) => e.id), [1, 2, 3]);
      expect(
        store.get(2)!.isBookmarked,
        isTrue,
        reason: 'bookmarked state must not regress',
      );
    });

    test('updateBookmark applies changes and clear resets everything', () {
      final store = IllustStore();
      store.mergeAll([entity(1)]);
      store.updateBookmark(1, true);
      expect(store.get(1)!.isBookmarked, isTrue);
      store.clear();
      expect(store.get(1), isNull);
    });

    test(
      'mergeAll round-trip preserves createDate through copyWith merges',
      () {
        // U2 regression: copyWith dropped createDate, so every merge that
        // touched an existing entity silently nulled the date.
        final store = IllustStore();
        final feed = entity(1);
        final dated = entity(1, createDate: '2026-08-29T12:00:00+09:00');
        store.mergeAll([feed]);
        // A later detail response carrying the date arrives; its merge goes
        // through copyWith (existing != null) and must keep the date.
        store.mergeAll([dated]);
        expect(store.get(1)!.createDate, '2026-08-29T12:00:00+09:00');
        // A date-less detail refresh must not erase the observed date.
        store.mergeAll([entity(1)]);
        expect(store.get(1)!.createDate, '2026-08-29T12:00:00+09:00');
        // Bookmark sync goes through copyWith too.
        store.updateBookmark(1, true);
        expect(store.get(1)!.createDate, '2026-08-29T12:00:00+09:00');
        // Unrelated merges must not affect the stored entity.
        store.mergeAll([entity(2), entity(1, bookmarked: true)]);
        expect(
          store.get(1)!.createDate,
          '2026-08-29T12:00:00+09:00',
          reason: 'createDate must survive every later merge and bookmark',
        );
      },
    );

    test(
      'detail merge may overwrite empty caption/tags, visible=false, smaller pageCount',
      () {
        // C3: EntityMergeSource.detail is authoritative — empty caption/tags,
        // visible=false and a reduced page count are real server state.
        final store = IllustStore();
        store.mergeAll([_richSparseTarget()]);
        store.mergeAll([
          _emptyAuthoritative(),
        ], source: EntityMergeSource.detail);
        final merged = store.get(1)!;
        expect(merged.caption, isEmpty);
        expect(merged.tags, isEmpty);
        expect(merged.visible, isFalse);
        expect(merged.pageCount, 1);
      },
    );

    test('feed merge does not regress caption/tags/pageCount', () {
      final store = IllustStore();
      store.mergeAll([_richSparseTarget()]);
      store.mergeAll([_emptyAuthoritative()]);
      final merged = store.get(1)!;
      expect(merged.caption, 'detail caption');
      expect(merged.tags.single.name, 'original');
      expect(merged.pageCount, 4);
      // Feed still uses `visible: new && old` (false sticks). That is not
      // the C3 "sparse does not apply visible=false" wording; do not freeze
      // either reading here — see the implementation report.
    });

    test('bookmark fields stay under BookmarkStore for feed and detail', () {
      final store = IllustStore();
      store.bindBookmarks(
        observeRemote: (id, bookmarked, restrict, snapshotRevision) {},
        authorityOf: (id) => true,
        revisionNow: () => 1,
      );
      store.mergeAll([_richSparseTarget()]);
      expect(store.get(1)!.isBookmarked, isTrue);

      store.mergeAll([_emptyAuthoritative()], source: EntityMergeSource.detail);
      expect(store.get(1)!.isBookmarked, isTrue);

      store.mergeAll([entity(1, bookmarked: false)]);
      expect(store.get(1)!.isBookmarked, isTrue);
    });

    test('copyWith exposes every constructor field (createDate included)', () {
      final original = entity(1);
      final copies = original.copyWith();
      // The invariant: copying without arguments keeps every non-mutable
      // field identical. Any future constructor field forgotten in
      // copyWith fails this test suite-wide.
      expect(copies.id, original.id);
      expect(copies.title, original.title);
      expect(copies.caption, original.caption);
      expect(copies.pageCount, original.pageCount);
      expect(copies.visible, original.visible);
      expect(copies.createDate, original.createDate);
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
        () => IllustEntity.parsePage({
          'illusts': [
            {'id': 'not-int'},
          ],
        }),
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
            'image_urls': {'square_medium': 'a', 'medium': 'b', 'large': 'c'},
            'user': {'id': 1, 'name': 'n', 'account': 'a'},
          },
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
