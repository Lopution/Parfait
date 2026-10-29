import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/core/search/search_history.dart';
import 'package:parfait/core/search/search_keywords.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/search/search_repository.dart';
import 'package:parfait/core/search/search_shortcut.dart';
import 'package:parfait/core/settings/preference_keys.dart';
import 'package:parfait/features/search/search_keyword_pills.dart';
import 'package:parfait/features/search/search_result_page.dart';
import 'package:parfait/features/search/search_page.dart';

import 'helpers/prompt_host.dart';
import 'helpers/search_world.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';

Future<GoRouter> _pumpInput(
  WidgetTester tester, {
  FakeSearchRepository? repository,
  List<String> history = const [],
  String location = '/search/input',
}) async {
  installMemoryPreferences({
    if (history.isNotEmpty) PreferenceKeys.searchHistory: history,
  });
  final router = pixivRouter(location);
  await tester.pumpWidget(
    localizedRouterApp(
      router,
      overrides: [
        searchRepositoryProvider.overrideWithValue(
          repository ?? FakeSearchRepository(),
        ),
      ],
      builder: promptHostBuilder,
    ),
  );
  // The input owns a focused TextField whose cursor schedules a persistent
  // frame; settle the route transition with a bounded pump instead.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return router;
}

String _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

Finder _historyChip(String keyword) => find.widgetWithText(InputChip, keyword);

List<String> _historyShown(WidgetTester tester) => [
  for (final chip in tester.widgetList<InputChip>(find.byType(InputChip)))
    (chip.label as Text).data!,
];

void main() {
  // The `paints` matcher records into a context that owns no layers: the
  // text field's LeaderLayers it builds there are never disposed.
  LeakTesting.settings = LeakTesting.settings.withIgnored(
    notDisposed: {'LeaderLayer': null},
  );
  group('searchShortcutFor', () {
    test('a bare number is an id of the selected kind', () {
      expect(
        searchShortcutFor(' 123 ', SearchResultType.illust),
        const SearchShortcut(SearchShortcutKind.illust, 123),
      );
      expect(
        searchShortcutFor('123', SearchResultType.novel),
        const SearchShortcut(SearchShortcutKind.novel, 123),
      );
      expect(
        searchShortcutFor('123', SearchResultType.user),
        const SearchShortcut(SearchShortcutKind.user, 123),
      );
      expect(searchShortcutFor('0', SearchResultType.illust), isNull);
      expect(searchShortcutFor('12a', SearchResultType.illust), isNull);
      expect(
        searchShortcutFor('1234567890123', SearchResultType.illust),
        isNull,
      );
    });

    test('a pixiv link opens what it names on any tab', () {
      for (final (link, expected) in [
        (
          'https://www.pixiv.net/artworks/42',
          const SearchShortcut(SearchShortcutKind.illust, 42),
        ),
        (
          'https://www.pixiv.net/en/artworks/42',
          const SearchShortcut(SearchShortcutKind.illust, 42),
        ),
        (
          'https://www.pixiv.net/users/7',
          const SearchShortcut(SearchShortcutKind.user, 7),
        ),
        (
          'https://www.pixiv.net/novel/show.php?id=9',
          const SearchShortcut(SearchShortcutKind.novel, 9),
        ),
        (
          'https://pixiv.net/en/novel/show.php?id=9',
          const SearchShortcut(SearchShortcutKind.novel, 9),
        ),
      ]) {
        expect(
          searchShortcutFor(link, SearchResultType.user),
          expected,
          reason: link,
        );
      }
    });

    test('anything else is a plain query', () {
      for (final text in [
        'cat',
        'https://example.com/artworks/42',
        'https://www.pixiv.net/tags/cat',
        'https://www.pixiv.net/novel/show.php?id=x',
        'pixiv.net/artworks/42',
      ]) {
        expect(
          searchShortcutFor(text, SearchResultType.illust),
          isNull,
          reason: text,
        );
      }
    });
  });

  group('search keywords', () {
    String inside(String text, TextRange? range) => range!.textInside(text);
    TextEditingValue at(String text, [int? caret]) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret ?? text.length),
    );

    test('spaces of either width split keywords; a space closes one', () {
      for (final (text, all, finished) in [
        ('原神 胡桃', ['原神', '胡桃'], ['原神']),
        ('原神\u3000胡桃 ', ['原神', '胡桃'], ['原神', '胡桃']),
        ('  a   b', ['a', 'b'], ['a']),
        ('', <String>[], <String>[]),
      ]) {
        String words(List<TextRange> ranges) =>
            ranges.map((r) => r.textInside(text)).join('|');
        expect(words(keywordRanges(text)), all.join('|'), reason: text);
        expect(
          words(finishedKeywordRanges(text)),
          finished.join('|'),
          reason: text,
        );
      }
    });

    test('the keyword at the caret is the one autocomplete works on', () {
      expect(inside('原神 胡', keywordAtCaret(at('原神 胡'))), '胡');
      expect(inside('原神 胡桃', keywordAtCaret(at('原神 胡桃', 1))), '原神');
      expect(keywordAtCaret(at('原神 ')), isNull);
      expect(keywordAtCaret(at('原神', 0)), isNull);
      expect(
        keywordAtCaret(
          const TextEditingValue(
            text: '原神',
            selection: TextSelection(baseOffset: 0, extentOffset: 2),
          ),
        ),
        isNull,
      );
      expect(completionQueryOf('-R-18'), 'R-18');
      expect(otherKeywords('原神 -胡桃 胡', const TextRange(start: 7, end: 8)), {
        '原神',
        '胡桃',
      });
    });

    test('a suggestion replaces the keyword, keeping its minus', () {
      for (final (before, caret, separate, after, caretAfter) in [
        ('原神 胡', 4, false, '原神 胡桃', 5),
        ('原神 胡', 4, true, '原神 胡桃 ', 6),
        ('-胡 原神', 2, true, '-胡桃 原神', 4),
        ('原神 胡\u3000x', 4, true, '原神 胡桃\u3000x', 6),
      ]) {
        final value = at(before, caret);
        final replaced = replaceKeyword(
          value,
          keywordAtCaret(value)!,
          '胡桃',
          thenSeparate: separate,
        );
        expect(replaced, at(after, caretAfter), reason: before);
      }
    });
  });

  group('SearchHistoryNotifier', () {
    late ProviderContainer container;

    // Each container reads the same in-memory store, like an app restart.
    ProviderContainer makeContainer() {
      final created = ProviderContainer.test();
      return created;
    }

    setUp(() {
      container = makeContainer();
    });

    SearchHistoryNotifier history() =>
        container.read(searchHistoryProvider.notifier);

    test('newest first, without repeats or blanks, capped', () async {
      container.listen(searchHistoryProvider, (_, _) {});
      await history().record('cat');
      await history().record('dog');
      await history().record(' ');
      await history().record('cat');
      expect(container.read(searchHistoryProvider), ['cat', 'dog']);
      for (var i = 0; i < SearchHistoryNotifier.maxEntries + 5; i++) {
        await history().record('k$i');
      }
      final entries = container.read(searchHistoryProvider);
      expect(entries, hasLength(SearchHistoryNotifier.maxEntries));
      expect(entries.first, 'k${SearchHistoryNotifier.maxEntries + 4}');
    });

    test('a removed entry goes back where it was', () async {
      container.listen(searchHistoryProvider, (_, _) {});
      for (final keyword in ['c', 'b', 'a']) {
        await history().record(keyword);
      }
      final index = await history().remove('b');
      expect(index, 1);
      expect(container.read(searchHistoryProvider), ['a', 'c']);
      await history().restore('b', index!);
      expect(container.read(searchHistoryProvider), ['a', 'b', 'c']);
      // Searched again in between: restoring must not duplicate it.
      await history().remove('b');
      await history().record('b');
      await history().restore('b', 2);
      expect(container.read(searchHistoryProvider), ['b', 'a', 'c']);
      expect(await history().remove('missing'), isNull);
    });

    test('survives a restart', () async {
      container.listen(searchHistoryProvider, (_, _) {});
      await history().record('cat');
      await history().record('dog');
      await pumpEventQueue();

      final restarted = makeContainer();
      restarted.listen(searchHistoryProvider, (_, _) {});
      await pumpEventQueue();
      expect(restarted.read(searchHistoryProvider), ['dog', 'cat']);

      await restarted.read(searchHistoryProvider.notifier).clear();
      await pumpEventQueue();
      final cleared = makeContainer();
      cleared.listen(searchHistoryProvider, (_, _) {});
      await pumpEventQueue();
      expect(cleared.read(searchHistoryProvider), isEmpty);
    });
  });

  testWidgets('the empty input offers recent searches and trending tags', (
    tester,
  ) async {
    final router = await _pumpInput(tester, history: ['dog', 'cat']);
    expect(find.text('搜索历史'), findsOneWidget);
    expect(_historyShown(tester), ['dog', 'cat']);
    expect(find.text('热门标签'), findsOneWidget);
    expect(find.widgetWithText(TagChip, '#猫'), findsOneWidget);

    // Tapping a recent search searches it again and moves it to the front.
    await tester.tap(_historyChip('cat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.state.uri.path, '/search/results');
    expect(router.state.uri.queryParameters['q'], 'cat');
    router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/search');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchHomePage)),
    );
    expect(container.read(searchHistoryProvider), ['cat', 'dog']);
  });

  testWidgets('removing a recent search offers undo; clearing all asks', (
    tester,
  ) async {
    await _pumpInput(tester, history: ['c', 'b', 'a']);
    await tester.tap(
      find.descendant(
        of: _historyChip('b'),
        matching: find.byTooltip('从搜索历史中删除'),
      ),
    );
    await tester.pumpAndSettle();
    expect(_historyShown(tester), ['c', 'a']);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(_historyShown(tester), ['c', 'b', 'a']);

    await tester.tap(find.text('清除全部'));
    await tester.pumpAndSettle();
    expect(find.text('清除全部搜索历史？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_historyShown(tester), hasLength(3));

    await tester.tap(find.text('清除全部'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('清除全部'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNothing);
    expect(find.text('搜索历史'), findsNothing);
  });

  testWidgets('suggestions complete the keyword at the caret', (tester) async {
    final asked = <String>[];
    final repository = FakeSearchRepository(
      autocompleteHandler: (keyword, _) async {
        asked.add(keyword);
        return const [
          SearchSuggestion(keyword: '胡桃', translatedName: 'Hu Tao'),
          SearchSuggestion(keyword: '原神'),
        ];
      },
    );
    final router = await _pumpInput(tester, repository: repository);
    Future<void> type(String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    // A pill's outline is the field's one rounded rectangle.
    Matcher pills(int count) => paintsExactlyCountTimes(#drawRRect, count);
    Finder pillsOf<T>() => find.descendant(
      of: find.byType(T),
      matching: find.byType(SearchKeywordPills),
    );

    await type('原神 -胡');
    expect(pillsOf<SearchInputPage>(), pills(1), reason: '-胡 is unfinished');
    expect(asked, ['胡'], reason: 'only the keyword at the caret, no minus');
    expect(find.text('原神'), findsNothing, reason: 'already in the query');
    await tester.longPress(find.text('Hu Tao'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/search/input');
    expect(_field(tester), '原神 -胡桃 ');
    expect(pillsOf<SearchInputPage>(), pills(2));
    expect(find.byType(ListTile), findsNothing, reason: 'next keyword');

    await type('原神 胡');
    await tester.tap(find.byTooltip('填入搜索框'));
    await tester.pumpAndSettle();
    expect(_field(tester), '原神 胡桃 ');

    await type('原神 胡');
    await tester.tap(find.text('Hu Tao'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/search/results');
    expect(router.state.uri.queryParameters['q'], '原神 胡桃');
    expect(pillsOf<SearchResultPage>(), pills(2), reason: 'all keywords');
  });

  testWidgets('submitting a search replaces input so back returns home', (
    tester,
  ) async {
    final router = await _pumpInput(tester);
    await tester.enterText(find.byType(TextField), 'cat');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-transition: the results page enters over the leaving input page
    // instead of swapping in place.
    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(find.byType(SearchResultPage), findsOneWidget);
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/search/results');
    expect(find.byType(SearchInputPage), findsNothing);
    router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/search');
    expect(find.byType(SearchInputPage), findsNothing);
    expect(find.byType(SearchHomePage), findsOneWidget);
  });

  testWidgets('a pixiv link or an id opens directly and is not recorded', (
    tester,
  ) async {
    final asked = <String>[];
    final repository = FakeSearchRepository(
      autocompleteHandler: (keyword, _) async {
        asked.add(keyword);
        return const [];
      },
    );
    final router = await _pumpInput(tester, repository: repository);
    await tester.enterText(
      find.byType(TextField),
      'https://www.pixiv.net/users/77',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('打开用户 ID 77'), findsOneWidget);
    expect(asked, isEmpty, reason: 'no tag suggestions for a link');

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, endsWith('/user/77'));

    router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/search');
    expect(find.byType(SearchInputPage), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchHomePage)),
    );
    expect(container.read(searchHistoryProvider), isEmpty);
  });
}
