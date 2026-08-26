import 'dart:convert';

import 'package:pixiv_func/core/entity/illust_entity.dart';

/// Canonical single-illust JSON for detail/store/viewer tests.
Map<String, dynamic> illustJson(
  int id, {
  bool bookmarked = false,
  int pageCount = 1,
  String type = 'illust',
  int xRestrict = 0,
  int aiType = 0,
  bool visible = true,
  bool withMetaPages = false,
  bool withMetaSinglePage = false,
  String caption = '',
  int totalView = 10,
  int totalBookmarks = 5,
  int width = 800,
  int height = 600,
}) =>
    {
      'id': id,
      'title': 'illust $id',
      'type': type,
      'image_urls': {
        'square_medium': 'https://i.pximg.net/$id/square.jpg',
        'medium': 'https://i.pximg.net/$id/medium.jpg',
        'large': 'https://i.pximg.net/$id/large.jpg',
        if (pageCount == 1) 'original': 'https://i.pximg.net/$id/original.jpg',
      },
      'caption': caption,
      'restrict': 0,
      'user': {
        'id': 99,
        'name': 'author',
        'account': 'author',
        'profile_image_urls': {'medium': 'https://i.pximg.net/u.jpg'},
      },
      'tags': [
        {'name': 'original'},
        {'name': '風景', 'translated_name': 'scenery'},
      ],
      'page_count': pageCount,
      'width': width,
      'height': height,
      'sanity_level': 2,
      'x_restrict': xRestrict,
      'illust_ai_type': aiType,
      'total_view': totalView,
      'total_bookmarks': totalBookmarks,
      'is_bookmarked': bookmarked,
      'visible': visible,
      'create_date': '2026-08-01T10:00:00+09:00',
      if (withMetaPages)
        'meta_pages': [
          for (var i = 0; i < pageCount; i++)
            {
              'image_urls': {
                'square_medium': 'https://i.pximg.net/$id/p$i/s.jpg',
                'medium': 'https://i.pximg.net/$id/p$i/m.jpg',
                'large': 'https://i.pximg.net/$id/p$i/l.jpg',
                'original': 'https://i.pximg.net/$id/p$i/original.jpg',
              },
            },
        ],
      if (withMetaSinglePage)
        'meta_single_page': {
          'original_image_url': 'https://i.pximg.net/$id/single_original.jpg',
        },
    };

IllustEntity parseIllust(Map<String, dynamic> json) =>
    IllustEntity.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
