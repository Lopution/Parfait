import 'review_support.dart';

/// Illust series and pixivision spotlight pages.
void main() {
  const series = '/recommended/series/500';
  const spotlight = '/recommended/spotlight';

  testShot('series/illust', location: series);
  testShot('spotlight/feed', location: spotlight);
  testShot(
    'spotlight/article',
    location:
        '$spotlight/article/101'
        '?url=${Uri.encodeComponent('https://www.pixivision.net/a/101')}',
  );

  testShot(
    'series/illust-loading',
    location: series,
    state: 'loading',
    setup: ReviewSetup(api: {'/v1/illust/series': reviewLoading()}),
  );
  testShot(
    'series/illust-error',
    location: series,
    state: 'error',
    setup: ReviewSetup(api: {'/v1/illust/series': reviewError()}),
  );
  testShot(
    'spotlight/feed-empty',
    location: spotlight,
    state: 'empty',
    setup: ReviewSetup(
      api: {'/v1/spotlight/articles': reviewEmpty('spotlight_articles')},
    ),
  );
  testShot(
    'spotlight/feed-error',
    location: spotlight,
    state: 'error',
    setup: ReviewSetup(api: {'/v1/spotlight/articles': reviewError()}),
  );
}
