import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/widgets/prompt_host.dart';
import 'package:parfait/app/widgets/search_field_button.dart';
import 'package:parfait/core/settings/preference_keys.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/search/docked_search.dart';
import 'package:parfait/features/search/search_page.dart';

import 'helpers/api_responses.dart';
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

  testWidgets('narrowing keeps the typed text and the filter drafts', (
    tester,
  ) async {
    final router = await _pump(tester);
    await _openDocked(tester);
    await tester.enterText(find.byType(TextField), '原神 ');
    await tester.pump(const Duration(milliseconds: 300));

    final panel = find.byType(DockedSearchPanel);
    expect(
      find.descendant(of: panel, matching: find.byTooltip('筛选')),
      findsOneWidget,
    );
    // Switching docked search to User hides the unsupported filter button.
    await tester.tap(find.descendant(of: panel, matching: find.text('用户')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: panel, matching: find.byTooltip('筛选')),
      findsNothing,
    );
    await tester.tap(
      find.descendant(of: panel, matching: find.text('插画 & 漫画')),
    );
    await tester.pumpAndSettle();
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
}
