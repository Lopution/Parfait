import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/pull_to_refresh.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/app/widgets/app_type_switch.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

const _two = [(value: 'illust', label: '插画'), (value: 'novel', label: '小说')];

Widget _boxHost({
  List<({String value, String label})> options = _two,
  String selected = 'illust',
  ValueChanged<String>? onSelected,
  double width = 411,
  double textScale = 1,
}) {
  return MaterialApp(
    theme: replicaTheme(Brightness.light),
    locale: const Locale('zh'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: const [Locale('zh')],
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: SizedBox(
          width: width,
          // Same vertical placement as the feed's state branches: the row
          // in a Column above the scrollable content.
          child: Column(
            children: [
              AppTypeSwitch<String>(
                options: options,
                selected: selected,
                onSelected: onSelected ?? (_) {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _sliverHost({bool disableAnimations = false}) {
  return MaterialApp(
    theme: replicaTheme(Brightness.light),
    locale: const Locale('zh'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: const [Locale('zh')],
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: PullToRefresh(
          onRefresh: () async {},
          child: CustomScrollView(
            slivers: [
              SliverAppTypeSwitch<String>(
                options: _two,
                selected: 'illust',
                onSelected: (_) {},
              ),
              SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(key: Key('first-card'), height: 200),
                  for (var i = 0; i < 20; i++)
                    SizedBox(key: Key('card-$i'), height: 120),
                ]),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Finder _switchRow() => find.byType(AppTypeSwitch<String>);

void main() {
  testWidgets('two options keep the row at 48dp at default scale', (
    tester,
  ) async {
    await tester.pumpWidget(_boxHost());
    await tester.pump();

    expect(tester.getSize(_switchRow()).height, lessThanOrEqualTo(48));
  });

  testWidgets('four options at 2x scroll horizontally instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _boxHost(
        options: const [
          (value: 'a', label: '每日排行'),
          (value: 'b', label: '每周排行'),
          (value: 'c', label: '每月排行'),
          (value: 'd', label: '新人排行'),
        ],
        textScale: 2,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: _switchRow(), matching: find.byType(Scrollable)),
    );
    await tester.drag(
      find.byType(SegmentedButton<String>),
      const Offset(-120, 0),
    );
    await tester.pump();
    expect(scrollable.position.pixels, greaterThan(0));
  });

  testWidgets('tapping another option reports it; tapping the current '
      'reports the current value', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(_boxHost(onSelected: picked.add));
    await tester.pump();

    await tester.tap(find.text('小说'));
    await tester.pump();
    expect(picked, ['novel']);

    // SegmentedButton reports an empty set on a same-option tap; the
    // switch turns it back into the current value — the host's re-tap.
    await tester.tap(find.text('插画'));
    await tester.pump();
    expect(picked, ['novel', 'illust']);
  });

  testWidgets('the selected option carries the check glyph', (tester) async {
    await tester.pumpWidget(_boxHost());
    await tester.pump();

    // Selection is not color-only: the M3 default check icon stays.
    expect(
      find.descendant(of: _switchRow(), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });

  group('sliver form inside PullToRefresh', () {
    Future<void> pumpFeed(WidgetTester tester, {bool noMotion = false}) async {
      tester.view.physicalSize = const Size(411, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_sliverHost(disableAnimations: noMotion));
      await tester.pump();
    }

    testWidgets('scrolls away with the list and floats back on a reverse', (
      tester,
    ) async {
      await pumpFeed(tester);
      expect(tester.getTopLeft(_switchRow()).dy, 0);

      // Scroll the list up: the row leaves with the content.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pump();
      expect(_switchRow(), findsNothing);

      // A downward drag brings it back floating over the content.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 30));
      await tester.pump();
      await tester.pumpAndSettle();
      final rect = tester.getRect(_switchRow());
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.top, lessThan(48));
    });

    testWidgets('an overscroll pull carries the row down with the list', (
      tester,
    ) async {
      await pumpFeed(tester);

      final card = find.byKey(const Key('first-card'));
      final cardTop = tester.getTopLeft(card).dy;
      final rowTop = tester.getTopLeft(_switchRow()).dy;

      // Pull 60px under the refresh trigger without releasing: the list
      // overscrolls (clamping: false), and the floating row must follow
      // the overshoot instead of staying pinned under the indicator.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CustomScrollView)),
      );
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();

      final cardDelta = tester.getTopLeft(card).dy - cardTop;
      expect(cardDelta, greaterThan(0), reason: 'the pull must overscroll');
      expect(
        tester.getTopLeft(_switchRow()).dy - rowTop,
        moreOrLessEquals(cardDelta, epsilon: 0.01),
        reason: 'a negative overlap must not pin the row to the top',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('with animations disabled the snap lands on the next frame', (
      tester,
    ) async {
      await pumpFeed(tester, noMotion: true);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pump();
      expect(_switchRow(), findsNothing);

      // Release a small reverse drag; with noAnimation the very next
      // frame is the fully-snapped row — no 225ms flight.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 30));
      await tester.pump();
      expect(tester.getTopLeft(_switchRow()).dy, 0);
      await tester.pumpAndSettle();
    });
  });
}
