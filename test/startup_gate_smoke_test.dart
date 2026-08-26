import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';
import 'package:pixiv_func/features/onboarding/startup_gate.dart';
import 'package:pixiv_func/features/onboarding/welcome_page.dart';

void main() {
  testWidgets('cold start shows the welcome shell before setup is complete', (
    tester,
  ) async {
    const settings = AppSettings(
      guideCompleted: false,
      languageTag: 'zh-CN',
      themeCode: AppSettings.systemTheme,
    );

    await tester.pumpWidget(
      const MaterialApp(home: StartupGate(settings: settings)),
    );

    expect(find.byType(WelcomePage), findsOneWidget);
    expect(find.text('感谢使用Pixiv Func'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
  });
}
