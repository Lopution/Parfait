import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/features/profile/profile_statistics.dart';

Finder _link(String id) => find.byKey(ValueKey('profile-stat-$id-header'));

Future<void> _pumpRow(
  WidgetTester tester, {
  required double width,
  required List<ProfileHeaderStat> stats,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: replicaTheme(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ProfileStatRow(stats: stats),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the blocks share one row, each a 48dp target', (tester) async {
    var tapped = <String>[];
    await _pumpRow(
      tester,
      width: 411,
      stats: [
        ProfileHeaderStat(
          id: 'following',
          value: 12,
          label: '关注',
          onTap: () => tapped.add('following'),
        ),
        ProfileHeaderStat(
          id: 'myPixiv',
          value: 3,
          label: '好P友',
          onTap: () => tapped.add('myPixiv'),
        ),
      ],
    );

    final following = tester.getRect(_link('following'));
    final myPixiv = tester.getRect(_link('myPixiv'));
    expect(following.top, myPixiv.top);
    expect(following.right, lessThan(myPixiv.left));
    expect(following.height, greaterThanOrEqualTo(48));
    // The figure sits over its label, and is the larger of the two.
    final figure = tester.getRect(find.text('12'));
    final label = tester.getRect(find.text('关注'));
    expect(figure.bottom, lessThanOrEqualTo(label.top));
    expect(figure.height, greaterThan(label.height));

    await tester.tap(_link('myPixiv'));
    await tester.tap(_link('following'));
    expect(tapped, ['myPixiv', 'following']);
    tapped = [];
  });

  testWidgets(
    'a block announces label and figure; a read-only one is no button',
    (tester) async {
      await _pumpRow(
        tester,
        width: 411,
        stats: [
          ProfileHeaderStat(
            id: 'following',
            value: 12,
            label: '关注',
            onTap: () {},
          ),
          const ProfileHeaderStat(id: 'myPixiv', value: 3, label: '好P友'),
        ],
      );
      expect(
        tester.getSemantics(_link('following')),
        isSemantics(label: '关注, 12', isButton: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(_link('myPixiv')),
        isSemantics(label: '好P友, 3', isButton: false, hasTapAction: false),
      );
    },
  );

  testWidgets('a narrow screen wraps the blocks instead of overflowing', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      width: 200,
      textScale: 1.3,
      stats: [
        ProfileHeaderStat(
          id: 'following',
          value: 1234,
          label: 'Подписки на авторов',
          onTap: () {},
        ),
        ProfileHeaderStat(
          id: 'myPixiv',
          value: 567,
          label: 'Мои друзья в Pixiv',
          onTap: () {},
        ),
      ],
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(_link('myPixiv')).top,
      greaterThan(tester.getRect(_link('following')).top),
    );
  });
}
