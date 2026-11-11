import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/widgets/app_tab_bar.dart';
import 'package:parfait/app/widgets/search_field_button.dart';
import 'package:parfait/core/settings/preference_keys.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/search/docked_search.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/search/search_result_page.dart';

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
      container: await searchWorld(search ?? SearchApi()),
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
}
