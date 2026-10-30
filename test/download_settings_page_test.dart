import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/settings/network_settings_page.dart';
import 'package:parfait/features/settings/pages/download_destination_page.dart';
import 'package:parfait/features/settings/pages/download_settings_page.dart';

import 'helpers/prompt_host.dart';
import 'helpers/settings_world.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';

void main() {
  Future<TextEditingController> pumpCustomTemplate(WidgetTester tester) async {
    await seedSettings(
      baseTestSettings().copyWith(
        namingRule: const NamingRule(
          preset: NamingPreset.custom,
          template: '{id}',
        ),
      ),
    );
    // Tall surface so the lazily-built template section exists.
    setViewSize(tester, const Size(800, 4000));
    await tester.pumpWidget(
      localizedApp(overrides: const [], home: DownloadSettingsPage()),
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

  testWidgets('on Android an album greys the caption switch out', (
    tester,
  ) async {
    for (final (destination, available) in const [
      (DownloadDestination.builtin, false),
      (DownloadDestination.safFolder('content://tree/x'), true),
    ]) {
      setViewSize(tester, const Size(800, 4000));
      await seedSettings(
        baseTestSettings().copyWith(
          downloadCaption: true,
          downloadDestination: destination,
        ),
      );
      await tester.pumpWidget(
        localizedApp(
          overrides: [
            platformCapsProvider.overrideWithValue(
              const PlatformCaps(isAndroid: true),
            ),
          ],
          home: DownloadSettingsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.widgetWithText(SwitchListTile, '同时导出作品简介')),
        isSemantics(
          hasEnabledState: true,
          isEnabled: available,
          hasToggledState: true,
          isToggled: available,
        ),
        reason: '$destination',
      );
      expect(
        find.text('相册不能存放文本文件；下载位置选「文件夹」时可用'),
        available ? findsNothing : findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    }
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

  testWidgets('a field edited during its save stays a draft', (tester) async {
    // (page, field index, first draft, edit typed while the write runs,
    // where the field is stored)
    for (final (page, field, draft, edit, stored)
        in <(Widget, int, String, String, String? Function(AppSettings))>[
          (
            const DownloadSettingsPage(),
            0,
            '{id}_a',
            '{id}_b',
            (settings) => settings.namingRule.template,
          ),
          (
            const DownloadDestinationPage(),
            0,
            'Album',
            'Album 2',
            (settings) => settings.downloadDestination.customAlbumName,
          ),
          (
            const NetworkAdvancedSettingsPage(),
            1,
            'a.example',
            'b.example',
            (settings) => settings.echFrontHost,
          ),
          (
            const NetworkSettingsPage(),
            0,
            'https://a.example',
            'https://b.x',
            (settings) => settings.customImageSource,
          ),
        ]) {
      final preferences = GatedPreferences(keys: settingsKeys);
      installPreferencesForTest(preferences);
      await seedSettings(
        baseTestSettings().copyWith(
          namingRule: const NamingRule(
            preset: NamingPreset.custom,
            template: '{id}',
          ),
        ),
      );
      setViewSize(tester, const Size(800, 4000));
      await tester.pumpWidget(
        localizedApp(
          overrides: const [],
          builder: promptHostBuilder,
          home: page,
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byType(TextField).at(field);
      await tester.enterText(input, draft);
      await tester.pump();
      final saving = Completer<void>();
      preferences.writeGate = saving.future;
      final writes = preferences.writes;
      await tester.tap(find.widgetWithText(FilledButton, '保存').first);
      await tester.pump();
      final reason = '${page.runtimeType}';
      // The save is held: its write started and has not landed.
      expect(preferences.writes, greaterThan(writes), reason: reason);
      expect(
        stored(await storedSettings().load()),
        isNot(draft),
        reason: reason,
      );
      await tester.enterText(input, edit);
      saving.complete();
      await tester.pumpAndSettle();

      expect(stored(await storedSettings().load()), draft, reason: reason);
      expect(
        tester.widget<TextField>(input).controller!.text,
        edit,
        reason: reason,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget, reason: reason);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
