import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/features/illust/detail/widgets/detail_page_counter.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/test_preferences.dart';

Widget host(Widget child, {Locale? locale}) => MaterialApp(
  localizationsDelegates: appLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: locale,
  home: child,
);

void main() {
  installMemoryPreferences();
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('hidden for single-page works, shows "N / M" for multi-page', (
    tester,
  ) async {
    await tester.pumpWidget(host(const DetailPageCounter(page: 0, count: 1)));
    expect(find.byType(Text), findsNothing);

    await tester.pumpWidget(host(const DetailPageCounter(page: 0, count: 3)));
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('exposes the viewer page label to screen readers', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const DetailPageCounter(page: 0, count: 3),
        locale: const Locale('zh', 'CN'),
      ),
    );

    // The pill speaks the localized "page n of N" label; the bare digits
    // stay excluded so the label is not read twice.
    expect(find.bySemanticsLabel('第 1 页，共 3 页'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('capsule uses the shared image-control surface and pill shape', (
    tester,
  ) async {
    await tester.pumpWidget(host(const DetailPageCounter(page: 1, count: 3)));

    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(DetailPageCounter),
        matching: find.byType(DecoratedBox),
      ),
    );
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, FuncTokens.imageControl);
    expect(decoration.borderRadius, FuncShape.pill);
  });

  testWidgets('never takes pointer input — taps reach the artwork below', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              child: const SizedBox.expand(),
            ),
            const Positioned.fill(child: DetailPageCounter(page: 0, count: 3)),
          ],
        ),
      ),
    );

    await tester.tapAt(tester.getRect(find.text('1 / 3')).center);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('fades in and out rather than cutting', (tester) async {
    double opacity() => tester
        .widget<FadeTransition>(
          find.descendant(
            of: find.byType(DetailPageCounter),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;

    await tester.pumpWidget(host(const DetailPageCounter(page: 0, count: 3)));
    expect(opacity(), 0);
    await tester.pump(const Duration(milliseconds: 90));
    expect(opacity(), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(opacity(), 1);

    // No page on screen: the pill keeps its last page while it fades out,
    // then leaves the tree.
    await tester.pumpWidget(
      host(const DetailPageCounter(page: null, count: 3)),
    );
    await tester.pump(const Duration(milliseconds: 90));
    expect(find.text('1 / 3'), findsOneWidget);
    expect(opacity(), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(find.byType(PageCountPill), findsNothing);
  });

  testWidgets('stays hidden until the entry transition completes', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(
                      body: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(
                            child: DetailPageCounter(page: 0, count: 3),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-flight the counter is not up yet — it must not join the Hero
    // landing frames.
    expect(find.text('1 / 3'), findsNothing);

    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
  });
}
