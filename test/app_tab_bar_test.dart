import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_tab_bar.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

Widget _host(
  List<String> labels, {
  double textScale = 1,
  ValueChanged<int>? onTap,
}) {
  return MaterialApp(
    theme: replicaTheme(Brightness.light),
    locale: const Locale('zh'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: const [Locale('zh')],
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        appBar: AppBar(
          title: DefaultTabController(
            length: labels.length,
            child: AppTabBar(labels: labels, onTap: onTap),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpBar(
  WidgetTester tester,
  List<String> labels, {
  double textScale = 1,
  ValueChanged<int>? onTap,
}) async {
  tester.view.physicalSize = const Size(411, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(labels, textScale: textScale, onTap: onTap));
  await tester.pump();
}

RichText _labelRichText(WidgetTester tester, String label) {
  return tester.widget<RichText>(
    find
        .descendant(
          of: find.ancestor(of: find.text(label), matching: find.byType(Tab)),
          matching: find.byType(RichText),
        )
        .first,
  );
}

void main() {
  testWidgets('eleven labels scroll from the start instead of shrinking', (
    tester,
  ) async {
    await _pumpBar(tester, const [
      '插画',
      '漫画',
      '小说',
      '推荐',
      '排行',
      '新作',
      '追更',
      '收藏',
      '历史',
      '发现',
      '关于',
    ]);

    final bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.isScrollable, isTrue);
    expect(bar.tabAlignment, TabAlignment.start);
  });

  testWidgets('labels stay 14sp and scroll instead of overflowing at 1.3x', (
    tester,
  ) async {
    const labels = ['每日排行', '昨日排行', '每周排行', '每月排行'];
    await _pumpBar(tester, labels, textScale: 1.3);

    expect(tester.takeException(), isNull);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isTrue);
    expect(
      (_labelRichText(tester, '每日排行').text as TextSpan).style!.fontSize,
      14,
    );
  });
}
