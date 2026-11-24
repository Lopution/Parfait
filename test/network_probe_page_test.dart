import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/core/network/compat/network_contracts.dart'
    hide NetworkMode;
import 'package:parfait/core/network/compat/network_probe.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/settings/network_probe_page.dart';
import 'package:parfait/features/settings/network_settings_page.dart';
import 'helpers/fake_settings.dart';
import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';

Widget _wrap(Widget child, {ProviderContainer? container}) {
  return localizedApp(
    container: container,
    overrides: container == null ? const [] : null,
    builder: promptHostBuilder,
    body: SingleChildScrollView(child: child),
  );
}

NetworkProbeReport _report(
  String host,
  NetworkProbeConclusion conclusion, {
  String? firstError,
  List<NetworkProbeStep> steps = const [],
}) {
  return NetworkProbeReport(
    host: host,
    purpose: PixivDestinationPurpose.appApi,
    steps: steps,
    conclusion: conclusion,
    firstError: firstError,
  );
}

void main() {
  testWidgets('probe overview lists counts, worst host and advice', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        NetworkProbeOverview(
          reports: {
            'app-api.pixiv.net': _report(
              'app-api.pixiv.net',
              NetworkProbeConclusion.allReachable,
            ),
            'oauth.secure.pixiv.net': _report(
              'oauth.secure.pixiv.net',
              NetworkProbeConclusion.allReachable,
            ),
            'i.pximg.net': _report(
              'i.pximg.net',
              NetworkProbeConclusion.sniBlocked,
              firstError: 'tls handshake reset',
            ),
          },
          errors: const {'panic.pixiv.net': 'boom'},
        ),
      ),
    );

    expect(find.text('探测总览'), findsOneWidget);
    // Counts row: one badge per observed conclusion plus its count, and the
    // failed-probe tally.
    expect(find.text('可访问'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('可访问')).style?.color,
      FuncTokens.white,
    );
    expect(find.text(' ×2'), findsOneWidget);
    // The worst conclusion appears twice: the counts row and the worst row.
    expect(find.text('SNI 被封'), findsNWidgets(2));
    expect(find.text(' ×1'), findsOneWidget);
    expect(find.text('主机探测失败 ×1'), findsOneWidget);
    expect(find.textContaining('最劣'), findsOneWidget);
    expect(find.textContaining('i.pximg.net'), findsOneWidget);
    expect(find.text('真实 SNI 被封——建议把网络模式设为「兼容优先」。'), findsOneWidget);
  });

  testWidgets('before a run the probe page lists its hosts unprobed', (
    tester,
  ) async {
    await seedSettings(
      const AppSettings(
        guideCompleted: true,
        languageTag: 'zh-CN',
        themeCode: AppSettings.systemTheme,
      ),
    );
    await tester.pumpWidget(
      localizedApp(overrides: const [], home: const NetworkProbePage()),
    );
    await tester.pump();

    expect(find.text('开始探测'), findsOneWidget);
    // No run yet: host cards render in the not-run state and no overview.
    expect(find.text('探测总览'), findsNothing);
    expect(find.text('尚未运行'), findsWidgets);
    // The default mirror re-lists the origin image host: probe it once.
    expect(find.text('i.pximg.net'), findsOneWidget);
  });

  testWidgets(
    'NetworkProbeOverview applies compatPrefer/DoH quick actions and NetworkAdvancedSettingsPage toggles enableDoh',
    (tester) async {
      await seedSettings(
        const AppSettings(
          guideCompleted: true,
          languageTag: 'zh-CN',
          themeCode: AppSettings.systemTheme,
          networkMode: NetworkMode.automatic,
          enableDoh: false,
        ),
      );
      final container = ProviderContainer.test();
      await container.read(settingsProvider.future);

      // 1. sniBlocked offers one-tap compatPrefer switch and hides once applied.
      await tester.pumpWidget(
        _wrap(
          NetworkProbeOverview(
            reports: {
              'i.pximg.net': _report(
                'i.pximg.net',
                NetworkProbeConclusion.sniBlocked,
              ),
            },
            errors: const {},
          ),
          container: container,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('切换到兼容优先'), findsOneWidget);
      await tester.tap(find.text('切换到兼容优先'));
      await tester.pumpAndSettle();
      expect(container.read(networkModeProvider), NetworkMode.compatPrefer);
      expect(find.text('切换到兼容优先'), findsNothing);

      // 2. dnsPolluted with DoH off offers one-tap DoH enable and hides once on.
      await tester.pumpWidget(
        _wrap(
          NetworkProbeOverview(
            reports: {
              'app-api.pixiv.net': _report(
                'app-api.pixiv.net',
                NetworkProbeConclusion.dnsPolluted,
              ),
            },
            errors: const {},
          ),
          container: container,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('开启 DoH 解析'), findsOneWidget);
      await tester.tap(find.text('开启 DoH 解析'));
      await tester.pumpAndSettle();
      expect(container.read(dohEnabledProvider), isTrue);
      expect(find.text('开启 DoH 解析'), findsNothing);

      // 3. NetworkAdvancedSettingsPage exposes enableDoh toggle and persists it.
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: const NetworkAdvancedSettingsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('严格回退使用 DoH 解析'), findsOneWidget);
      await tester.tap(find.text('严格回退使用 DoH 解析'));
      await tester.pumpAndSettle();
      expect(container.read(dohEnabledProvider), isFalse);
    },
  );
}
