import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/network_probe.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';
import 'package:pixiv_func/core/settings/settings_controller.dart';
import 'package:pixiv_func/core/settings/settings_repository.dart';
import 'package:pixiv_func/features/settings/network_probe_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

class _FakeRepository implements SettingsRepository {
  AppSettings value = const AppSettings(
    guideCompleted: true,
    languageTag: 'zh-CN',
    themeCode: AppSettings.systemTheme,
  );

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async {
    value = settings;
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'CN'),
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

  testWidgets('host panel keeps step details folded until expanded', (
    tester,
  ) async {
    final report = _report(
      'app-api.pixiv.net',
      NetworkProbeConclusion.sniBlocked,
      firstError: 'tls handshake reset',
      steps: const [
        NetworkProbeStep(name: 'system-dns', ok: true, detail: '2 addrs'),
        NetworkProbeStep(name: 'tls', ok: false, detail: 'reset'),
      ],
    );
    await tester.pumpWidget(
      _wrap(
        NetworkProbeHostPanel(
          host: 'app-api.pixiv.net',
          report: report,
          error: null,
          running: false,
        ),
      ),
    );

    // Summary row: host, conclusion badge and the first error stay visible;
    // the step list lives behind the collapsed details tile.
    expect(find.text('app-api.pixiv.net'), findsOneWidget);
    expect(find.text('tls handshake reset'), findsOneWidget);
    final tile = tester.widget<ExpansionTile>(find.byType(ExpansionTile));
    expect(tile.initiallyExpanded, isFalse);
    final collapsedHeight = tester.getSize(find.byType(Card)).height;

    await tester.tap(find.text('明细'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(Card)).height,
      greaterThan(collapsedHeight),
    );
    expect(find.textContaining('系统 DNS'), findsWidgets);
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('probe page states results are not persisted', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(_FakeRepository()),
        ],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: const NetworkProbePage(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('结果不保存——离开本页即丢失。'), findsOneWidget);
    expect(find.text('开始探测'), findsOneWidget);
    // No run yet: host cards render in the not-run state and no overview.
    expect(find.text('探测总览'), findsNothing);
    expect(find.text('尚未运行'), findsWidgets);
  });
}
