import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/settings/pages/download_settings_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/settings_world.dart';

void main() {
  late FakeSettingsRepository repository;

  Future<TextEditingController> pumpCustomTemplate(WidgetTester tester) async {
    repository = FakeSettingsRepository(
      baseTestSettings().copyWith(
        namingRule: const NamingRule(
          preset: NamingPreset.custom,
          template: '{id}',
        ),
      ),
    );
    // Tall surface so the lazily-built template section exists.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: DownloadSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.widget<TextField>(find.byType(TextField)).controller!;
  }

  Finder chip(String label) => find.widgetWithText(ActionChip, label);

  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(chip(label));
    await tester.pump();
  }

  bool fieldFocused(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus;

  testWidgets('a chip inserts at the cursor and keeps the field focused', (
    tester,
  ) async {
    final controller = await pumpCustomTemplate(tester);
    controller.selection = const TextSelection.collapsed(offset: 0);

    await tapChip(tester, '标题');

    expect(controller.text, '{title}{id}');
    expect(controller.selection, const TextSelection.collapsed(offset: 7));
    expect(fieldFocused(tester), isTrue);
    expect(find.textContaining('预览：作品标题123456'), findsOneWidget);

    // The draft is unsaved: save is offered and leaving asks first.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNotNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
  });

  testWidgets('a variable that would pass the limit is not inserted', (
    tester,
  ) async {
    final controller = await pumpCustomTemplate(tester);
    final full = '{id}${'a' * 121}';
    controller.value = TextEditingValue(
      text: full,
      selection: TextSelection.collapsed(offset: full.length),
    );

    await tapChip(tester, '作者名');
    expect(controller.text, full);

    // `{w}` still fits: 125 + 3 = 128.
    await tapChip(tester, '宽度');
    expect(controller.text, '$full{w}');
  });

  testWidgets('the limit counts characters, as the field does', (tester) async {
    final controller = await pumpCustomTemplate(tester);
    // 121 + 4 characters, but each emoji is two UTF-16 units.
    final full = '{id}${'😀' * 121}';
    controller.value = TextEditingValue(
      text: full,
      selection: TextSelection.collapsed(offset: full.length),
    );

    await tapChip(tester, '宽度');
    expect(controller.text, '$full{w}');
  });
}
