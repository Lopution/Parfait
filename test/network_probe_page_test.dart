import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/network_probe.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/settings/network_probe_page.dart';
import 'helpers/fake_settings.dart';
import 'helpers/localized_app.dart';

Widget _wrap(Widget child) {
  return localizedApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
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
    await tester.pumpWidget(
      localizedApp(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(
              const AppSettings(
                guideCompleted: true,
                languageTag: 'zh-CN',
                themeCode: AppSettings.systemTheme,
              ),
            ),
          ),
        ],
        home: const NetworkProbePage(),
      ),
    );
    await tester.pump();

    expect(find.text('开始探测'), findsOneWidget);
    // No run yet: host cards render in the not-run state and no overview.
    expect(find.text('探测总览'), findsNothing);
    expect(find.text('尚未运行'), findsWidgets);
    // The default mirror re-lists the origin image host: probe it once.
    expect(find.text('i.pximg.net'), findsOneWidget);
  });
}
