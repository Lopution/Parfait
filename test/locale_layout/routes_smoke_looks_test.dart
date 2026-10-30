import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../helpers/illust_fixtures.dart';
import '../helpers/locale_layout.dart';
import '../helpers/route_smoke.dart';
import '../review/review_support.dart';

/// One page of each layout the app has, for the looks a phone can take.
const _pages = [
  '/recommended', '/recommended/illust/1001', '/ranking/illust/1002/viewer/1',
  '/new/user/3000', '/search/results?q=cat&type=illust', '/me/novel/2000', //
  '/settings/all', '/me',
];

const _detail = '/recommended/illust/1001';
const _viewer = '/recommended/illust/1001/viewer/0';

/// Text long enough to wrap anywhere, with emoji and full-width letters.
final _long = 'Ｐａｒｆａｉｔ 🎨🌸 long text ' * 10;

Map<String, dynamic> _work(Map<String, dynamic> changes) => {
  ...reviewIllustJson(1001),
  ...changes,
};

/// What a work or user page reads, in a state the default world never has.
final _extremes = <String, (String, Map<String, ReviewResponder>)>{
  'very wide': (_viewer, _illust(_work({'width': 11588, 'height': 4500}))),
  'very tall': (_detail, _illust(_work({'width': 800, 'height': 24000}))),
  '200 pages': (
    '/recommended/illust/1001/viewer/199',
    _illust(illustJson(1001, pageCount: 200, withMetaPages: true)),
  ),
  'ugoira': (_detail, _illust(_work({'type': 'ugoira'}))),
  'private': (_detail, _illust(_work({'visible': false}))),
  'R-18 and AI': (
    _detail,
    _illust(_work({'x_restrict': 1, 'illust_ai_type': 2})),
  ),
  'long text and zero counts': (
    _detail,
    _illust(
      _work({
        'title': _long,
        'caption': _long * 3,
        'tags': [
          for (var i = 0; i < 30; i++)
            {'name': '$i$_long', 'translated_name': _long},
        ],
        'user': {...reviewUserJson(99), 'name': _long},
        'total_view': 0,
        'total_bookmarks': 0,
        'total_comments': 0,
      }),
    ),
  ),
  'deleted': (_detail, {'/v1/illust/detail': _gone('该作品已被删除，或作品ID不存在。')}),
  'deleted user': ('/new/user/3000', {'/v1/user/detail': _gone('该用户不存在。')}),
  'long user': (
    '/new/user/3000',
    {
      '/v1/user/detail': reviewJson({
        ...reviewUserDetailJson(3000),
        'user': {...reviewUserJson(3000), 'name': _long, 'comment': _long * 5},
      }),
    },
  ),
  'long novel': (
    '/me/novel/2000',
    {
      '/v2/novel/detail': reviewJson({
        'novel': {
          ...reviewNovelJson(2000),
          'title': _long,
          'tags': [
            for (var i = 0; i < 30; i++) {'name': '$i$_long'},
          ],
          'total_bookmarks': 0,
          'total_view': 0,
          'total_comments': 0,
        },
      }),
    },
  ),
  'deleted novel': ('/me/novel/2000', {'/v2/novel/detail': _gone('该小说已被删除。')}),
};

Map<String, ReviewResponder> _illust(Map<String, dynamic> json) => {
  '/v1/illust/detail': reviewJson({'illust': json}),
};

/// The App API's answer for a work or user that no longer exists.
ReviewResponder _gone(String message) =>
    (_) async => http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'error': {'user_message': message, 'message': ''},
        }),
      ),
      404,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  smokeHarness();
  final regular = smokeDevice(LayoutProfile.regular);
  for (final location in _pages) {
    testWidgets('$location dark', (tester) async {
      await smokeScene(
        tester,
        location: location,
        brightness: Brightness.dark,
        content: true,
      );
    });
    testWidgets('$location text 2.0', (tester) async {
      // Compact: a FitLabel may ellipsize past its floor, as it does there.
      await smokeScene(
        tester,
        location: location,
        device: regular,
        textScale: 2,
        profile: LayoutProfile.compact,
        content: true,
      );
    });
    for (final device in const ['tablet-landscape', 'phone-landscape']) {
      testWidgets('$location $device', (tester) async {
        await smokeScene(
          tester,
          location: location,
          device: reviewDevices[device],
          content: true,
        );
      });
    }
  }
  for (final MapEntry(key: name, value: (location, api)) in _extremes.entries) {
    testWidgets('$location $name', (tester) async {
      await smokeScene(
        tester,
        location: location,
        setup: ReviewSetup(api: api),
        content: !name.startsWith('deleted'),
      );
    });
  }
}
