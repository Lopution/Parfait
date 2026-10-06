import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:parfait/core/history/history_models.dart';

import '../helpers/illust_fixtures.dart';

/// Fixture JSON builders for the review world's API dispatch. Real API
/// envelopes so the real repositories parse them; ids are stable so every
/// run produces the same frames.

Map<String, dynamic> reviewIllustJson(
  int id, {
  bool bookmarked = false,
  int pageCount = 1,
  String caption = '',
}) => illustJson(
  id,
  bookmarked: bookmarked,
  pageCount: pageCount,
  withMetaPages: pageCount > 1,
  caption: caption,
);

Map<String, dynamic> reviewNovelJson(int id, {bool bookmarked = false}) => {
  'id': id,
  'title': 'novel $id',
  'caption': 'caption $id',
  'restrict': 0,
  'x_restrict': 0,
  'is_original': false,
  'is_bookmarked': bookmarked,
  'text_length': 4000 + id,
  'total_bookmarks': 30 + id,
  'total_view': 200 + id,
  'total_comments': 3,
  'visible': true,
  'is_muted': false,
  'is_mypixiv_only': false,
  'is_x_restricted': false,
  'novel_ai_type': 0,
  'create_date': '2026-08-01T10:00:00+09:00',
  'user': {
    'id': 99,
    'name': 'author',
    'account': 'author',
    'profile_image_urls': {'medium': 'https://i.pximg.net/u.jpg'},
  },
  'tags': [
    {'name': '原创', 'translated_name': 'original'},
    {'name': 'fantasy'},
  ],
  'image_urls': {
    'square_medium': 'https://i.pximg.net/n$id/square.jpg',
    'medium': 'https://i.pximg.net/n$id/medium.jpg',
    'large': 'https://i.pximg.net/n$id/large.jpg',
  },
  'series': {'id': 77, 'title': 'series 77'},
};

Map<String, dynamic> reviewNovelDetailJson(int id) => {
  'novel': reviewNovelJson(id),
};

/// The `/webview/v2/novel` bootstrap page, same shape as
/// novel_webview_text_test's fixture: `Object.defineProperty` installs
/// `window.pixiv.novel`.
String reviewNovelWebviewHtml(int id, {int paragraphs = 6}) {
  final text = [
    for (var i = 0; i < paragraphs; i++) '第${i + 1}段：novel $id 的正文内容。',
  ].join('\n\n');
  final novel = jsonEncode({
    'id': '$id',
    'title': 'novel $id',
    'text': text,
    'userId': '99',
    'coverUrl': 'https://i.pximg.net/n$id/medium.jpg',
    'tags': ['原创', 'fantasy'],
    'caption': 'caption $id',
    'seriesNavigation': {
      'prev': {'id': '70', 'title': 'novel 70'},
      'next': {'id': '80', 'title': 'novel 80'},
    },
  });
  return '''
<!DOCTYPE html><html><head></head><body>
<script>
Object.defineProperty(window, 'pixiv', {value: {
  "context": {"csrfToken": "x"},
  "novel": $novel,
}, configurable: true, writable: true});
</script>
</body></html>
''';
}

Map<String, dynamic> reviewUserJson(int id) => {
  'id': id,
  'name': 'user $id',
  'account': 'user_$id',
  'profile_image_urls': {'medium': 'https://i.pximg.net/u$id.jpg'},
  'comment': 'bio of user $id',
};

Map<String, dynamic> reviewUserPreviewJson(int id) => {
  'user': reviewUserJson(id),
  'illusts': [reviewIllustJson(9000 + id), reviewIllustJson(9010 + id)],
  'novels': <Map<String, dynamic>>[],
  'is_muted': false,
};

Map<String, dynamic> reviewUserDetailJson(int id) => {
  'user': {
    ...reviewUserJson(id),
    'is_followed': false,
    'is_access_blocking_user': false,
  },
  'profile': {
    'webpage': 'https://example.com/u$id',
    'gender': 'unknown',
    'birth': '2000-01-01',
    'birth_day': '01-01',
    'birth_year': 2000,
    'region': 'Japan',
    'address_id': 42,
    'country_code': 'JP',
    'job': 'creator',
    'job_id': 1,
    'total_follow_users': 50,
    'total_mypixiv_users': 5,
    'total_illusts': 120,
    'total_manga': 10,
    'total_novels': 8,
    'total_illust_bookmarks_public': 200,
    'total_illust_series': 2,
    'total_novel_series': 1,
    'twitter_account': '',
    'twitter_url': '',
    'pawoo_url': '',
    'is_premium': false,
    'is_using_custom_profile_image': true,
    'background_image_url': 'https://i.pximg.net/u$id/bg.jpg',
  },
  'profile_publicity': {
    'gender': 'public',
    'region': 'public',
    'birth_day': 'public',
    'birth_year': 'public',
    'job': 'public',
    'pawoo': 'public',
  },
  'workspace': {
    'pc': 'pc',
    'monitor': 'monitor',
    'tool': 'tool',
    'scanner': 'scanner',
    'tablet': 'tablet',
    'mouse': 'mouse',
    'printer': 'printer',
    'desktop': 'desktop',
    'music': 'music',
    'desk': 'desk',
    'chair': 'chair',
    'comment': 'workspace comment',
    'workspace_image_url': null,
  },
};

Map<String, dynamic> reviewCommentJson(
  int id,
  int workId, {
  String? stampUrl,
}) => {
  'id': id,
  'comment': 'comment $id on $workId',
  'date': '2026-09-01T10:00:00+09:00',
  'user': reviewUserJson(7000 + id),
  'has_replies': id == 1,
  if (stampUrl != null) 'stamp': {'stamp_url': stampUrl},
};

Map<String, dynamic> reviewTrendTagJson(int id) => {
  'tag': 'tag$id',
  'translated_name': '翻译$id',
  'illust': reviewIllustJson(9500 + id),
};

Map<String, dynamic> reviewBookmarkTagJson(String tag) => {
  'name': tag,
  'count': 4,
};

Map<String, dynamic> reviewWatchlistJson(int id) => {
  'id': id,
  'title': 'watchlist series $id',
  'user': reviewUserJson(99),
  'latest_content_id': id + 600,
  'last_published_content_datetime':
      '2026-09-${(id % 28 + 1).toString().padLeft(2, '0')}T12:00:00+09:00',
  'published_content_count': id + 3,
  'url': 'https://i.pximg.net/w$id.jpg',
};

/// Five illusts then three novels in the signed-in account's history,
/// newest first.
List<HistoryRecord> reviewHistory() => [
  for (var i = 0; i < 5; i++)
    HistoryRecord(
      accountId: '100',
      contentType: HistoryContentType.illust,
      contentId: 1000 + i,
      lastViewedAt: DateTime(2026, 9, 30).subtract(Duration(hours: i)),
      snapshot: HistorySnapshot(
        title: 'illust ${1000 + i}',
        authorName: 'author',
        coverUrl: 'https://i.pximg.net/${1000 + i}/square.jpg',
      ),
    ),
  for (var i = 0; i < 3; i++)
    HistoryRecord(
      accountId: '100',
      contentType: HistoryContentType.novel,
      contentId: 2000 + i,
      lastViewedAt: DateTime(2026, 9, 29).subtract(Duration(hours: i)),
      snapshot: HistorySnapshot(
        title: 'novel ${2000 + i}',
        authorName: 'author',
        coverUrl: 'https://i.pximg.net/n${2000 + i}/square.jpg',
      ),
    ),
];

/// Deterministic art: a gradient per picture, so shots show where each
/// image lands without real assets. Every size of one picture — square,
/// medium, large, original, a page's own URLs — shares its colours, as on
/// pixiv, so a hero flight or a medium-to-large swap does not change the
/// picture. The shape follows the fixtures: works are their 800×600
/// metadata, square crops and avatars square, covers and the rest portrait.
class ReviewImageBytes {
  ReviewImageBytes._();

  static final _cache = <String, Uint8List>{};

  static const _sizeNames = {
    'square', 'medium', 'large', 'original', 's', 'm', 'l', '360', '1200', //
  };

  static Uint8List forUrl(String url) =>
      _cache.putIfAbsent(url, () => _render(url));

  static Uint8List _render(String url) {
    final segments = Uri.parse(url).pathSegments;
    final file = segments.last.split('.').first;
    final isWork = int.tryParse(segments.first) != null;
    final picture = isWork
        ? '${segments.first}/${segments.length > 2 ? segments[1] : 'p0'}'
        : _sizeNames.contains(file)
        ? segments.take(segments.length - 1).join('/')
        : segments.join('/');
    final isAvatar = segments.length == 1 && file.startsWith('u');
    final (w, h) = file == 'square' || file == 's' || isAvatar
        ? (300, 300)
        : isWork
        ? (400, 300)
        : (300, 420);
    final seed = picture.hashCode & 0xFFFFFF;
    final hue = seed % 360;
    final top = img.ColorRgb8(
      60 + (hue * 2 % 140),
      80 + (hue * 5 % 120),
      120 + (hue * 3 % 120),
    );
    final bottom = img.ColorRgb8(
      40 + (hue * 7 % 100),
      60 + (hue * 4 % 110),
      90 + (hue * 6 % 130),
    );
    final image = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      final t = y / (h - 1);
      final r = (top.r + (bottom.r - top.r) * t).round();
      final g = (top.g + (bottom.g - top.g) * t).round();
      final b = (top.b + (bottom.b - top.b) * t).round();
      for (var x = 0; x < w; x++) {
        image.setPixelRgb(x, y, r, g, b);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }
}
