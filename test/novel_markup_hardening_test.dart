import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/novel/novel_entity.dart';
import 'package:pixiv_func/features/novel/novel_layout.dart';
import 'package:pixiv_func/features/novel/novel_reader.dart';

void main() {
  test('novel markup produces typed tokens and visible fallbacks', () {
    final document = NovelMarkupParser().parse(
      '正文😀\n'
      '[[chapter:第一章]]\n'
      '[[rb:漢字 > かんじ]] [[jump:下一页 > 2]] '
      '[[jumpuri:作品 > https://www.pixiv.net/artworks/88]] '
      '[[pixivimage:123]] [[uploadedimage:cover-1.png]]\n'
      '[[future:payload]] [[rb:损坏]] [[pixivimage:not-an-id]] '
      '[[jumpuri:外链 > https://example.com/blocked]]\n'
      '[[newpage]]末页',
    );

    expect(document.tokens.whereType<NovelTextToken>(), isNotEmpty);
    expect(document.tokens.whereType<NovelChapterToken>(), hasLength(1));
    expect(document.tokens.whereType<NovelRubyToken>(), hasLength(2));
    expect(document.tokens.whereType<NovelJumpToken>(), hasLength(3));
    expect(document.tokens.whereType<NovelPixivImageToken>(), hasLength(2));
    expect(document.tokens.whereType<NovelUploadedImageToken>(), hasLength(1));
    expect(document.tokens.whereType<NovelUnknownToken>(), hasLength(1));
    expect(document.tokens.whereType<NovelNewPageToken>(), hasLength(1));
    expect(document.imageRequests, hasLength(2));
    expect(document.imageRequests[0].identifier, '123');
    expect(document.imageRequests[0].source, NovelImageSource.pixiv);
    expect(document.imageRequests[1].identifier, 'cover-1.png');
    expect(document.imageRequests[1].source, NovelImageSource.uploaded);
    expect(document.unsupportedTokens, hasLength(4));
    expect(document.plainText, contains('[[future:payload]]'));
    expect(document.plainText, contains('[[rb:损坏]]'));
    expect(document.plainText, contains('[[pixivimage:not-an-id]]'));
    expect(
      document.plainText,
      contains('[[jumpuri:外链 > https://example.com/blocked]]'),
    );
    expect(document.blocks.whereType<NovelChapterBlock>(), hasLength(1));
    expect(document.blocks.whereType<NovelPageBreakBlock>(), hasLength(1));
  });

  test('novel parser keeps raw attributes and reports malformed nesting', () {
    final document = NovelMarkupParser().parse(
      '[[Future:raw [[nested]] value]] tail',
    );
    final token = document.tokens.whereType<NovelUnknownToken>().single;

    expect(token.rawName, 'Future');
    expect(token.rawText, '[[Future:raw [[nested]] value]]');
    expect(token.attributes['payload'], 'raw [[nested]] value');
    expect(token.isMalformed, isTrue);
    expect(document.plainText, startsWith('[[Future:raw [[nested]] value]]'));
  });

  test('cancellable parser is bounded and reports progress', () async {
    final progress = <NovelMarkupProgress>[];
    final parser = NovelMarkupParser(
      budget: const NovelMarkupBudget(
        maxSourceUnits: 1024,
        maxTokens: 4,
        chunkSize: 2,
      ),
    );

    final result = await parser.parseCancellable(
      'a b c d e f g h i j',
      onProgress: progress.add,
    );

    expect(result.document.budgetExceeded, isTrue);
    expect(
      result.document.tokens.whereType<NovelBudgetExceededToken>(),
      hasLength(1),
    );
    expect(progress, isNotEmpty);
    expect(progress.last.processedUnits, lessThanOrEqualTo(1024));
    expect(progress.last.tokenCount, lessThanOrEqualTo(4));
    expect(result.progress.isComplete, isTrue);
  });

  test(
    'cancellable parser exposes cancellation instead of partial success',
    () async {
      final token = CancelToken()..cancel();

      await expectLater(
        NovelMarkupParser().parseCancellable('long body', cancelToken: token),
        throwsA(isA<ApiCancelled>()),
      );
    },
  );

  test(
    'document layout honors chapter/page boundaries and layout budget',
    () async {
      final document = NovelMarkupParser().parse(
        'before\n[[chapter:第二章]]\nchapter body[[newpage]]after',
      );
      final progress = <NovelLayoutProgress>[];
      final layout = await NovelLayoutEngine().layoutDocumentCancellable(
        document: document,
        contentVersion: 'markup-v1',
        viewport: const Size(240, 160),
        style: const NovelLayoutStyle(fontSize: 14, lineHeight: 1.2),
        textColor: Colors.black,
        brightness: Brightness.light,
        budget: const NovelLayoutBudget(chunkParagraphs: 1),
        onProgress: progress.add,
      );

      expect(layout.pages.length, greaterThanOrEqualTo(3));
      expect(layout.pages.any((page) => page.chapterTitle == '第二章'), isTrue);
      expect(progress, isNotEmpty);
      expect(progress.last.isComplete, isTrue);

      await expectLater(
        NovelLayoutEngine().layoutDocumentCancellable(
          document: document,
          contentVersion: 'markup-v1-budget',
          viewport: const Size(240, 160),
          style: const NovelLayoutStyle(),
          textColor: Colors.black,
          brightness: Brightness.light,
          budget: const NovelLayoutBudget(maxTextUnits: 2),
        ),
        throwsA(isA<NovelLayoutBudgetExceeded>()),
      );
    },
  );

  test('reader gate rejects stale chapter and disposed layout results', () {
    final gate = NovelReaderCommitGate();
    final first = gate.beginLayout(
      contentVersion: 'v1',
      chapterId: 'chapter-1',
      pageIndex: 2,
    );
    final second = gate.beginLayout(
      contentVersion: 'v1',
      chapterId: 'chapter-2',
      pageIndex: 0,
    );

    expect(first.cancelToken.isCancelled, isTrue);
    var committed = false;
    expect(
      gate.commit(
        first,
        contentVersion: 'v1',
        chapterId: 'chapter-1',
        action: () => committed = true,
      ),
      isFalse,
    );
    expect(committed, isFalse);
    expect(
      gate.commit(
        second,
        contentVersion: 'v1',
        chapterId: 'chapter-2',
        action: () => committed = true,
      ),
      isTrue,
    );
    expect(committed, isTrue);

    gate.dispose();
    expect(
      gate.commit(
        second,
        contentVersion: 'v1',
        chapterId: 'chapter-2',
        action: () {},
      ),
      isFalse,
    );
  });
}
