import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

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
