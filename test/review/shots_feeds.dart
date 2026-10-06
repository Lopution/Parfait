import 'review_support.dart';

/// History, watch-later, watchlist, bookmark tags, tag search and downloads.
void main() {
  const tag = '风景';

  testShot(
    'history/list',
    location: '/recommended/history',
    setup: ReviewSetup(history: reviewHistory()),
    variants: {ShotVariant.dark, ShotVariant.talkBack},
  );
  testShot(
    'watchlater/list',
    location: '/recommended/watchlater',
    setup: const ReviewSetup(watchlater: 5),
  );
  testShot('watchlist/list', location: '/recommended/watchlist');
  testShot('bookmarks/tags', location: '/recommended/bookmarks/tags');
  testShot(
    'bookmarks/tag-feed',
    location: '/recommended/bookmarks/tag?tag=${Uri.encodeComponent(tag)}',
  );
  testShot(
    'tag/search',
    location: '/recommended/tag/${Uri.encodeComponent(tag)}',
  );
  testShot(
    'downloads/tasks',
    location: '/downloads',
    setup: const ReviewSetup(downloadGroups: 1, downloadSingles: 4),
    variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.talkBack},
  );

  testShot('history/empty', location: '/recommended/history', state: 'empty');
  testShot(
    'watchlater/empty',
    location: '/recommended/watchlater',
    state: 'empty',
  );
  testShot(
    'watchlist/empty',
    location: '/recommended/watchlist',
    state: 'empty',
    setup: ReviewSetup(
      api: {
        '/v1/watchlist/manga': reviewEmpty('series'),
        '/v1/watchlist/novel': reviewEmpty('series'),
      },
    ),
  );
  testShot('downloads/empty', location: '/downloads', state: 'empty');
  testShot(
    'bookmarks/tags-empty',
    location: '/recommended/bookmarks/tags',
    state: 'empty',
    setup: ReviewSetup(
      api: {
        '/v1/user/bookmark-tags/illust': reviewJson(const {
          'bookmark_tags': <Object?>[],
        }),
        '/v1/user/bookmark-tags/novel': reviewJson(const {
          'bookmark_tags': <Object?>[],
        }),
      },
    ),
  );
}
