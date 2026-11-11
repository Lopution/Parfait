import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/widgets/app_tab_bar.dart';
import 'package:parfait/app/widgets/page_header.dart';
import 'package:parfait/app/widgets/prompt_host.dart';
import 'package:parfait/app/widgets/search_field_button.dart';
import 'package:parfait/core/debug/trace_marks.dart';
import 'package:parfait/core/settings/preference_keys.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/search/docked_search.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/search/search_result_page.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/search_world.dart';
import 'helpers/test_preferences.dart';
import 'helpers/view_size.dart';

/// The app's shell at [location] on [view], signed in with [search]'s API.
/// Esc and prompts are wired the way the app does it, so the panel's
/// keyboard and scrim behaviour is the real one.
Future<GoRouter> _pump(
  WidgetTester tester, {
  String location = '/recommended',
  Size view = const Size(1280, 800),
  SearchApi? search,
  Map<String, ApiRoute> routes = const {},
  List<String> history = const [],
}) async {
  installMemoryPreferences({
    if (history.isNotEmpty) PreferenceKeys.searchHistory: history,
  });
  setViewSize(tester, view);
  final router = pixivRouter(location);
  await tester.pumpWidget(
    localizedRouterApp(
      router,
      container: await searchWorld(search ?? SearchApi(), routes: routes),
      builder: (context, child) => KeyboardBack(
        router: router,
        child: promptHostBuilder(context, child),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return router;
}

/// The recommended page's header search field.
Finder _headerField() => find.descendant(
  of: find.byType(RecommendedHomePage),
  matching: find.byType(SearchFieldButton),
);

/// Taps the header field and lets the panel's entrance settle.
Future<void> _openDocked(WidgetTester tester, {Finder? field}) async {
  await tester.tap(field ?? _headerField());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('a wide header docks the input under the field', (tester) async {
    final router = await _pump(tester);
    final anchor = tester.getRect(_headerField());

    await _openDocked(tester);
    final panel = find.byType(DockedSearchPanel);
    expect(panel, findsOneWidget);
    expect(find.byType(SearchInputPage), findsNothing);
    // Same width as the trigger (at least 360), under it, inside content.
    final rect = tester.getRect(panel);
    expect(rect.top, greaterThanOrEqualTo(anchor.bottom));
    expect(rect.width, greaterThanOrEqualTo(360));
    expect(rect.width, closeTo(anchor.width, 0.01));
    expect(rect.right, closeTo(anchor.right, 0.01));

    await tester.enterText(find.byType(TextField), 'cat');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(panel, findsNothing);
    expect(router.state.uri.path, '/recommended/search/results');
    expect(router.state.uri.queryParameters['q'], 'cat');
    expect(find.byType(SearchResultPage), findsOneWidget);
  });

  testWidgets('editing the query on a wide result bar replaces the results', (
    tester,
  ) async {
    final router = await _pump(
      tester,
      location: '/recommended/search/results?q=cat&type=illust',
    );
    final field = find.byType(SearchFieldButton);
    expect(field, findsOneWidget);

    await _openDocked(tester, field: field);
    expect(find.byType(DockedSearchPanel), findsOneWidget);
    expect(_fieldText(tester), 'cat');

    await tester.enterText(find.byType(TextField), 'dog');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(DockedSearchPanel), findsNothing);
    expect(router.state.uri.path, '/recommended/search/results');
    expect(router.state.uri.queryParameters['q'], 'dog');
    // Replaced in place: back returns to the destination, not the old query.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/recommended');
  });

  testWidgets('Esc leaves the field first, a second Esc closes the panel', (
    tester,
  ) async {
    final router = await _pump(tester);
    await _openDocked(tester);
    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(DockedSearchPanel), findsOneWidget);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DockedSearchPanel), findsNothing);
    expect(router.state.uri.path, '/recommended');
  });

  testWidgets('the scrim and the system back close the panel', (tester) async {
    final router = await _pump(tester);
    await _openDocked(tester);
    // Over the dimmed page, inside the content area and clear of the panel.
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DockedSearchPanel), findsNothing);
    expect(router.state.uri.path, '/recommended');

    await _openDocked(tester);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DockedSearchPanel), findsNothing);
    expect(router.state.uri.path, '/recommended');
  });

  testWidgets('narrowing carries the draft to the full page', (tester) async {
    final router = await _pump(tester);
    await _openDocked(tester);
    await tester.enterText(find.byType(TextField), 'cat');
    await tester.pump(const Duration(milliseconds: 50));

    setViewSize(tester, const Size(390, 844));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(DockedSearchPanel), findsNothing);
    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(router.state.uri.path, '/recommended/search/input');
    expect(router.state.uri.queryParameters['q'], 'cat');
    expect(_fieldText(tester), 'cat');
  });

  testWidgets('a phone keeps the full input page', (tester) async {
    final router = await _pump(
      tester,
      location: '/search',
      view: const Size(390, 844),
    );

    await tester.tap(find.byType(SearchFieldButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(find.byType(DockedSearchPanel), findsNothing);
    expect(router.state.uri.path, '/search/input');
  });

  testWidgets('the panel offers history, kinds and filters', (tester) async {
    final router = await _pump(tester, history: ['dog', 'cat']);
    await _openDocked(tester);

    final panel = find.byType(DockedSearchPanel);
    expect(
      find.descendant(
        of: panel,
        matching: find.widgetWithText(InputChip, 'cat'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.byType(AppTabBar)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.byTooltip('筛选')),
      findsOneWidget,
    );

    // A history entry searches at once, like the full page's.
    await tester.tap(find.widgetWithText(InputChip, 'cat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DockedSearchPanel), findsNothing);
    expect(router.state.uri.path, '/recommended/search/results');
    expect(router.state.uri.queryParameters['q'], 'cat');
  });

  testWidgets('a resize re-anchors the panel under the entry', (tester) async {
    final router = await _pump(tester);
    await _openDocked(tester);
    final panel = find.byType(DockedSearchPanel);

    // The rail stays; only the content area narrows.
    setViewSize(tester, const Size(1024, 800));
    await tester.pump();
    // The panel re-anchors once the page below has laid out.
    await tester.pump();
    final field = tester.getRect(_headerField());
    var rect = tester.getRect(panel);
    expect(rect.width, closeTo(field.width, 0.01));
    expect(rect.right, closeTo(field.right, 0.01));
    expect(rect.top, greaterThanOrEqualTo(field.bottom));

    // Narrower still the field becomes an icon; the panel stays under it,
    // keeps its minimum width and inside the window.
    setViewSize(tester, const Size(900, 800));
    await tester.pump();
    await tester.pump();
    final icon = tester.getRect(
      find.descendant(
        of: find.byType(HeaderSearch),
        matching: find.byType(IconButton),
      ),
    );
    rect = tester.getRect(panel);
    expect(rect.width, 360);
    expect(rect.right, closeTo(icon.right, 0.01));
    expect(rect.top, greaterThanOrEqualTo(icon.bottom));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(800));
    expect(router.state.uri.path, '/recommended');
  });

  testWidgets('narrowing keeps the typed text and the filter drafts', (
    tester,
  ) async {
    final router = await _pump(tester);
    await _openDocked(tester);
    await tester.enterText(find.byType(TextField), '原神 ');
    await tester.pump(const Duration(milliseconds: 300));

    final panel = find.byType(DockedSearchPanel);
    await tester.tap(
      find.descendant(of: panel, matching: find.byTooltip('筛选')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('纵向'));
    await tester.pump();
    await tester.tap(find.text('纵向'));
    await tester.pump();
    await tester.ensureVisible(find.text('应用'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    setViewSize(tester, const Size(390, 844));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(DockedSearchPanel), findsNothing);
    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(router.state.uri.path, '/recommended/search/input');
    // The trailing space is part of the draft, not something to trim.
    expect(_fieldText(tester), '原神 ');
    expect(find.byTooltip('筛选（已启用 1 项）'), findsOneWidget);
  });

  testWidgets('narrowing with the filter sheet open closes both layers', (
    tester,
  ) async {
    final router = await _pump(tester);
    await _openDocked(tester);
    final panel = find.byType(DockedSearchPanel);
    await tester.tap(
      find.descendant(of: panel, matching: find.byTooltip('筛选')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('应用'), findsOneWidget);

    setViewSize(tester, const Size(390, 844));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('应用'), findsNothing);
    expect(find.byType(DockedSearchPanel), findsNothing);
    // Neither layer's scrim is left over the full page.
    expect(find.byType(PromptCover), findsNothing);
    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(router.state.uri.path, '/recommended/search/input');
  });

  testWidgets('a shortcut closes the panel before the page it names', (
    tester,
  ) async {
    // The detail page's visibility check would leave its timer pending.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    final router = await _pump(
      tester,
      routes: {
        '/v1/illust/detail': (_) async =>
            jsonResponse({'illust': illustJson(123)}),
        '/v2/illust/related': (_) async =>
            jsonResponse(pageJson('illusts', const [])),
        '/v3/illust/comments': (_) async => jsonResponse({
          'comments': const <Object?>[],
          'total_comments': 0,
          'next_url': null,
        }),
        '/v1/illust-series/illust': (_) async => jsonResponse(const {}),
        '/v1/user/illusts': (_) async =>
            jsonResponse(pageJson('illusts', const [])),
      },
    );
    await _openDocked(tester);
    await tester.enterText(find.byType(TextField), '123');
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('打开插画/漫画 ID 123'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.byType(DockedSearchPanel), findsNothing);
    expect(find.byType(PromptCover), findsNothing);
    expect(router.state.uri.path, '/recommended/illust/123');
    expect(find.byType(IllustDetailPage), findsOneWidget);
  });

  testWidgets('the panel and its fade are marked as scenes', (tester) async {
    final marks = <String>[];
    TraceMarks.sink = marks.add;
    addTearDown(TraceMarks.debugReset);

    await _pump(tester);
    await _openDocked(tester);
    expect(
      marks,
      containsAllInOrder([
        'enter panel',
        'event panel in',
        'enter docked search',
        'event docked search open',
      ]),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(
      marks,
      containsAllInOrder([
        'enter panel',
        'event panel out',
        'exit panel',
        'event docked search end',
        'exit docked search',
      ]),
    );
  });
}
