import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/pull_to_refresh.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_type_switch.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

const _two = [(value: 'illust', label: '插画'), (value: 'novel', label: '小说')];

/// Overflows a 360dp row at 2x text.
const _four = [
  (value: 'a', label: '每日排行'),
  (value: 'b', label: '每周排行'),
  (value: 'c', label: '每月排行'),
  (value: 'd', label: '新人排行'),
];

Widget _boxHost({
  List<({String value, String label})> options = _two,
  String selected = 'illust',
  ValueChanged<String>? onSelected,
  double width = 411,
  double textScale = 1,
  ScrollBehavior? scrollBehavior,
  GestureDragEndCallback? onPageSwipe,
}) {
  return MaterialApp(
    theme: replicaTheme(Brightness.light),
    locale: const Locale('zh'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: const [Locale('zh')],
    scrollBehavior: scrollBehavior,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        // Stands in for RootSwipeSwitcher: a translucent horizontal drag
        // detector around the page.
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: onPageSwipe,
          child: SizedBox(
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
    ),
  );
}

Widget _sliverHost({
  List<({String value, String label})> options = _two,
  double textScale = 1,
  bool disableAnimations = false,
  RefreshCallback? onRefresh,
}) {
  return MaterialApp(
    theme: replicaTheme(Brightness.light),
    locale: const Locale('zh'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: const [Locale('zh')],
    home: MediaQuery(
      data: MediaQueryData(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(
        body: PullToRefresh(
          onRefresh: onRefresh ?? () async {},
          child: CustomScrollView(
            slivers: [
              SliverAppTypeSwitch<String>(
                options: options,
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
    var pageSwipes = 0;
    await tester.pumpWidget(
      _boxHost(
        options: _four,
        textScale: 2,
        scrollBehavior: const FuncScrollBehavior(),
        onPageSwipe: (_) => pageSwipes++,
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
    // An overflowing row owns the drag, like any deeper horizontal
    // scrollable under RootSwipeSwitcher.
    expect(pageSwipes, 0);
  });

  testWidgets('a row that fits leaves sideways drags to the page', (
    tester,
  ) async {
    // FuncScrollBehavior gives every scrollable an always-scrollable
    // parent; inherited, it would make the fitting row claim the drag.
    var pageSwipes = 0;
    await tester.pumpWidget(
      _boxHost(
        scrollBehavior: const FuncScrollBehavior(),
        onPageSwipe: (_) => pageSwipes++,
      ),
    );
    await tester.pump();

    await tester.drag(
      find.byType(SegmentedButton<String>),
      const Offset(-200, 0),
    );
    await tester.pump();
    expect(pageSwipes, 1);
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

  testWidgets('the selection is the fill and the selected semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_boxHost());
    await tester.pump();

    // No check glyph: it would widen the selected segment and shift the
    // labels when the selection moves. Screen readers get the selection.
    expect(
      find.descendant(of: _switchRow(), matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    expect(
      tester.getSemantics(find.text(_two.first.label)),
      isSemantics(isSelected: true, isInMutuallyExclusiveGroup: true),
    );
    expect(
      tester.getSemantics(find.text(_two.last.label)),
      isSemantics(isSelected: false, isInMutuallyExclusiveGroup: true),
    );
    semantics.dispose();
  });

  group('sliver form inside PullToRefresh', () {
    Future<void> pumpFeed(
      WidgetTester tester, {
      double width = 411,
      List<({String value, String label})> options = _two,
      double textScale = 1,
      bool noMotion = false,
      RefreshCallback? onRefresh,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _sliverHost(
          options: options,
          textScale: textScale,
          disableAnimations: noMotion,
          onRefresh: onRefresh,
        ),
      );
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

    testWidgets('a sideways drag on the row never pulls to refresh', (
      tester,
    ) async {
      var refreshes = 0;
      await pumpFeed(
        tester,
        onRefresh: () async {
          refreshes++;
        },
      );

      // EasyRefresh hands its physics to every descendant scrollable.
      // Inherited, a rightward drag would overscroll the row and arm the
      // refresh header.
      await tester.drag(
        find.byType(SegmentedButton<String>),
        const Offset(300, 0),
      );
      await tester.pumpAndSettle();
      expect(refreshes, 0);
    });

    testWidgets('an overflowing row scrolls on its own, not into a refresh', (
      tester,
    ) async {
      var refreshes = 0;
      await pumpFeed(
        tester,
        width: 360,
        options: _four,
        textScale: 2,
        onRefresh: () async {
          refreshes++;
        },
      );
      final segments = find.byType(SegmentedButton<String>);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: _switchRow(), matching: find.byType(Scrollable)),
      );

      // Past the start edge from rest: the bounce stays on the row.
      await tester.drag(segments, const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(refreshes, 0);
      expect(scrollable.position.pixels, 0);

      await tester.drag(segments, const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(0));
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
