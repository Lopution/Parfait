import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/novel/novel_entity.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/features/novel/novel_layout.dart';
import 'package:pixiv_func/features/novel/novel_reader.dart';

void main() {
  test(
    'Novel mapper keeps paragraphs, ruby marks and unknown marks visible',
    () {
      final paragraphs = NovelContentMapper.fromText(
        '第一[[rb:漢字 > かんじ]]\n\n未知 [[future:payload]]',
      );

      expect(paragraphs, hasLength(3));
      expect(paragraphs[0].text, '第一漢字');
      expect(paragraphs[0].inlineMarks.single.kind, 'rb');
      expect(paragraphs[0].inlineMarks.single.value, 'かんじ');
      expect(paragraphs[1].text, isEmpty);
      expect(paragraphs[2].text, '未知 [[future:payload]]');
      expect(paragraphs[2].inlineMarks.single.isUnknown, isTrue);
    },
  );

  test('Novel detail mapper keeps metadata and versions JSON body content', () {
    final first = NovelEntity.fromDetailJson(_novelJson('hello'));
    final second = NovelEntity.fromDetailJson(_novelJson('hello again'));

    expect(first.id, 77);
    expect(first.title, 'A novel');
    expect(first.user.name, 'author');
    expect(first.seriesId, 12);
    expect(first.tags.single.translatedName, 'tag translated');
    expect(first.contentAvailable, isTrue);
    expect(first.paragraphs.single.text, 'hello');
    expect(first.contentVersion, isNot(second.contentVersion));
  });

  test('layout cache is keyed by content, viewport and typography', () {
    final cache = NovelLayoutCache(maxEntries: 2);
    final engine = NovelLayoutEngine(cache: cache);
    final paragraphs = [
      for (var index = 0; index < 80; index++)
        NovelParagraph(id: 'p$index', text: 'paragraph $index ' * 8),
    ];
    const style = NovelLayoutStyle(fontSize: 14, lineHeight: 1.4);

    final first = engine.layout(
      paragraphs: paragraphs,
      contentVersion: 'v1',
      viewport: const Size(180, 160),
      style: style,
      textColor: Colors.black,
      brightness: Brightness.light,
    );
    final cached = engine.layout(
      paragraphs: paragraphs,
      contentVersion: 'v1',
      viewport: const Size(180, 160),
      style: style,
      textColor: Colors.black,
      brightness: Brightness.light,
    );
    final changedViewport = engine.layout(
      paragraphs: paragraphs,
      contentVersion: 'v1',
      viewport: const Size(240, 160),
      style: style,
      textColor: Colors.black,
      brightness: Brightness.light,
    );

    expect(first.pages.length, greaterThan(1));
    expect(identical(first, cached), isTrue);
    expect(changedViewport.key.viewport, const Size(240, 160));
    expect(cache.length, 2);
    expect(first.progressPercent(0), 0);
    expect(first.progressPercent(first.pages.length - 1), 100);
    expect(
      first.pageIndexForAnchor(first.pages.last.startAnchor),
      first.pages.length - 1,
    );
  });

  test('reader tap zones and page progress are bounded and monotonic', () {
    final reader = NovelReaderController(pageCount: 4);

    expect(reader.zoneForTap(0, 100), NovelTapZone.previous);
    expect(reader.zoneForTap(29, 100), NovelTapZone.previous);
    expect(reader.zoneForTap(50, 100), NovelTapZone.center);
    expect(reader.zoneForTap(71, 100), NovelTapZone.next);
    expect(reader.zoneForTap(100, 100), NovelTapZone.next);
    expect(reader.handleTap(50, 100), isFalse);
    expect(reader.currentPage, 0);
    expect(reader.handleTap(90, 100), isTrue);
    expect(reader.currentPage, 1);
    expect(reader.progressPercent, closeTo(33.333, 0.01));
    reader.setPage(99);
    expect(reader.currentPage, 3);
    expect(reader.progressPercent, 100);
    expect(reader.next(), isFalse);
  });

  test(
    'layout cancellation is observable instead of returning stale pages',
    () async {
      final token = CancelToken()..cancel();
      final engine = NovelLayoutEngine();

      await expectLater(
        engine.layoutCancellable(
          paragraphs: [
            for (var index = 0; index < 20; index++)
              NovelParagraph(id: 'p$index', text: 'body'),
          ],
          contentVersion: 'v1',
          viewport: const Size(240, 320),
          style: const NovelLayoutStyle(),
          textColor: Colors.black,
          brightness: Brightness.light,
          cancelToken: token,
        ),
        throwsA(isA<ApiCancelled>()),
      );
    },
  );

  testWidgets('NovelReader exposes horizontal PageView and percentage', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NovelReader(novel: _novel('reader ' * 120))),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);

    await tester.tapAt(const Offset(370, 300));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(PageView), findsOneWidget);
  });
}

NovelEntity _novel(String text) => NovelEntity(
  id: 77,
  title: 'A novel',
  caption: 'caption',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: const [],
  textLength: text.length,
  contentVersion: text,
  paragraphs: NovelContentMapper.fromText(text),
  contentAvailable: true,
);

Map<String, dynamic> _novelJson(String content) => {
  'novel': {
    'id': 77,
    'title': 'A novel',
    'caption': 'caption',
    'restrict': 0,
    'x_restrict': 0,
    'image_urls': {'medium': 'https://i.pximg.net/cover.png'},
    'tags': [
      {'name': 'tag', 'translated_name': 'tag translated'},
    ],
    'text_length': content.length,
    'content': content,
    'user': {
      'id': 8,
      'name': 'author',
      'account': 'author',
      'profile_image_urls': {'medium': 'https://i.pximg.net/avatar.png'},
    },
    'series': {'id': 12, 'title': 'Series'},
    'visible': true,
  },
};
