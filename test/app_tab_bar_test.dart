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
  testWidgets('four short labels share equal slots when they fit', (
    tester,
  ) async {
    await _pumpBar(tester, const ['推荐', '排行', '新作', '追更']);

    final bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.isScrollable, isFalse);
    expect(bar.tabAlignment, TabAlignment.fill);
    // Slots live in the Expanded wrappers; a Tab's own box keeps its
    // natural label size even when the bar fills the row.
    final widths = [
      for (var i = 0; i < 4; i++)
        tester
            .getRect(
              find.ancestor(
                of: find.byType(Tab).at(i),
                matching: find.byType(Expanded),
              ),
            )
            .width,
    ];
    for (final width in widths) {
      expect(width, moreOrLessEquals(widths.first, epsilon: 0.01));
    }
  });

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

  testWidgets('a set that fit at 1x scrolls at 2x, labels stay 14sp', (
    tester,
  ) async {
    const labels = ['每日排行', '昨日排行', '每周排行', '每月排行'];
    await _pumpBar(tester, labels);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isFalse);

    await _pumpBar(tester, labels, textScale: 2);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isTrue);
    // R5: fitting is decided by measurement, never by shrinking the font.
    expect(
      (_labelRichText(tester, '每日排行').text as TextSpan).style!.fontSize,
      14,
    );
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

  testWidgets('label style is the resolved 14sp w500 platform style', (
    tester,
  ) async {
    await _pumpBar(tester, const ['推荐', '排行']);

    final context = tester.element(find.byType(AppTabBar));
    // The provenance matters: the style must come from the resolved
    // textTheme so labels keep the platform family (D3).
    final style = TabBarTheme.of(context).labelStyle!;
    expect(style.fontSize, 14);
    expect(style.fontWeight, FontWeight.w500);
    expect(style.fontFamily, 'Roboto');
    expect((_labelRichText(tester, '推荐').text as TextSpan).style!.fontSize, 14);
  });

  testWidgets('onTap receives the tapped index verbatim', (tester) async {
    final tapped = <int>[];
    await _pumpBar(tester, const ['推荐', '排行', '新作'], onTap: tapped.add);

    await tester.tap(find.text('新作'));
    await tester.pump();
    expect(tapped, [2]);
    await tester.tap(find.text('新作'));
    await tester.pump();
    expect(tapped, [2, 2]);
  });

  test('preferredSize matches the equivalent TabBar', () {
    const labels = ['a', 'bb', 'ccc'];
    expect(
      const AppTabBar(labels: labels).preferredSize,
      TabBar(
        tabs: [for (final label in labels) Tab(text: label)],
      ).preferredSize,
    );
  });
}
