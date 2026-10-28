import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/card_columns.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/author_summary.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/feed/feed_text_warmup.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/novel_entry.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/user/user_entity.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/warm_text.dart';

List<WarmText> _lines(int count) => [
  for (var i = 0; i < count; i++)
    (
      span: TextSpan(text: 'title $i', style: const TextStyle(fontSize: 14)),
      locale: null,
      strutStyle: null,
    ),
];

void _add(FeedTextWarmup warmup, int count) => warmup.add(
  _lines(count),
  item: 0,
  textScaler: TextScaler.noScaling,
  textDirection: TextDirection.ltr,
);

void main() {
  testWidgets('warms one line per frame gap, and only after a short frame', (
    tester,
  ) async {
    // An indeterminate spinner keeps the next frame scheduled, as a fling
    // does.
    await tester.pumpWidget(
      const MaterialApp(home: CircularProgressIndicator()),
    );
    var now = Duration.zero;
    final warmup = FeedTextWarmup(clock: () => now);
    _add(warmup, 3);

    // Frame 1 starts at 0 and nothing runs inside it.
    await tester.pump(const Duration(milliseconds: 16));
    expect(warmup.pendingCount, 3);

    // Its gap opens 1 ms after it started: room for one line, not two.
    now = const Duration(milliseconds: 1);
    await tester.pump(const Duration(milliseconds: 16));
    expect(warmup.pendingCount, 2);

    // Frame 2 started at 1 ms and ran 4 ms: a slow line would overrun the
    // vsync, so this gap is skipped.
    now = const Duration(milliseconds: 5);
    await tester.pump(const Duration(milliseconds: 16));
    expect(warmup.pendingCount, 2);

    now = const Duration(milliseconds: 6);
    await tester.pump(const Duration(milliseconds: 16));
    expect(warmup.pendingCount, 1);
    // Disposing with a gap pending leaves no timer or frame callback.
    warmup.dispose();
  });

  testWidgets('with no frame on the way, drains without scheduling one', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final warmup = FeedTextWarmup();
    _add(warmup, 3);

    await tester.pump(Duration.zero);
    expect(warmup.pendingCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    warmup.dispose();
  });

  testWidgets('the window holds the lines just past the furthest built item', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    // No pump below: queued lines stay pending.
    final warmup = FeedTextWarmup();
    final window = FeedTextWindow(warmup: warmup);
    final asked = <int>[];
    List<WarmText> twoLines(BuildContext context, int index) {
      asked.add(index);
      return _lines(2);
    }

    const items = FeedTextWindow.maxTexts ~/ 2;
    window.update(context, count: 100, head: 1, texts: twoLines);
    expect(asked, [for (var i = 0; i < items; i++) i]);
    expect(warmup.pendingCount, FeedTextWindow.maxTexts);

    // Items 0–9 are built: their lines leave, 30–39 join.
    window.built(context, 9);
    expect(asked.skip(items), [for (var i = items; i < items + 10; i++) i]);
    expect(warmup.pendingCount, FeedTextWindow.maxTexts);
    // Building an earlier item again changes nothing.
    window.built(context, 3);
    expect(asked, hasLength(items + 10));

    // A jump past the window skips the items it never reached.
    asked.clear();
    window.built(context, 80);
    expect(asked, [for (var i = 81; i < 100; i++) i]);
    expect(warmup.pendingCount, 19 * 2);

    // A refreshed feed (another head, or fewer items) starts over.
    for (final (count, head) in [(100, 2), (10, 2)]) {
      asked.clear();
      window.update(context, count: count, head: head, texts: twoLines);
      expect(asked.first, 0, reason: 'count $count head $head');
      expect(asked, hasLength(count < items ? count : items));
    }
    window.dispose();
  });

  testWidgets('feed lists move the window with the items they build', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(900, 600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const count = 200;
    final built = <int>{};
    final asked = <int>[];
    List<WarmText> twoLines(BuildContext context, int index) {
      asked.add(index);
      return _lines(2);
    }

    Widget item(BuildContext context, int index) {
      built.add(index);
      return const SizedBox(height: 100);
    }

    final lists = <String, Widget>{
      'grid': IllustFeedGrid(
        itemCount: count,
        warmTexts: twoLines,
        itemBuilder: item,
      ),
      'card list': SliverCardList(
        itemCount: count,
        firstId: 1,
        warmTexts: twoLines,
        itemBuilder: item,
      ),
    };
    for (final MapEntry(key: name, value: list) in lists.entries) {
      built.clear();
      asked.clear();
      final controller = ScrollController();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: CustomScrollView(controller: controller, slivers: [list]),
          ),
        ),
      );
      int furthest(Iterable<int> indices) => indices.reduce(math.max);
      const ahead = FeedTextWindow.maxTexts ~/ 2;
      expect(furthest(asked), furthest(built) + ahead, reason: name);

      controller.jumpTo(3000);
      await tester.pump();
      expect(furthest(built), greaterThan(ahead), reason: name);
      expect(furthest(asked), furthest(built) + ahead, reason: name);
      controller.dispose();
    }
  });

  testWidgets('warm lines match the paragraphs the cards lay out', (
    tester,
  ) async {
    final illust = parseIllust(illustJson(6)..['title'] = 'ある日の絵');
    final novel = NovelEntity(
      id: 1,
      title: 'ある日の物語',
      caption: '',
      user: const UserEntity(id: 8, name: '小林', account: 'kobayashi'),
      tags: const [
        NovelTag(name: 'オリジナル'),
        NovelTag(name: 'R-18'),
      ],
      seriesTitle: '日々',
      textLength: 4321,
      contentVersion: 'v1',
      paragraphs: const [],
    );
    late BuildContext context;
    await tester.pumpWidget(
      ProviderScope(
        child: localizedApp(
          theme: replicaTheme(Brightness.light),
          // The bold-text setting is merged after the card's style.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(boldText: true),
            child: child!,
          ),
          body: Builder(
            builder: (c) {
              context = c;
              return ListView(
                children: [
                  // As the recommended users list lays it out.
                  const Card(
                    child: AuthorSummary(
                      name: 'ねこ',
                      account: '@neko',
                      imageUrl: null,
                    ),
                  ),
                  NovelEntry.compact(entity: novel),
                  SizedBox(width: 300, child: IllustCard(entity: illust)),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final lines = [
      ...NovelEntry.warmTexts(context, novel),
      ...IllustCard.warmTexts(context, illust),
      ...AuthorSummary.warmTexts(context, name: 'ねこ', account: '@neko'),
    ];
    expectLaidOutAsWarmed(tester, lines);
    expect(lines.map((l) => l.locale?.languageCode), [
      'ja',
      'zh',
      'zh',
      'ja',
      'ja',
      'zh',
      'ja',
      'zh',
    ]);
  });
}
