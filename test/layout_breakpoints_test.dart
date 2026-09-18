import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:pixiv_func/app/layout/app_breakpoints.dart';
import 'package:pixiv_func/app/layout/two_pane.dart';

void main() {
  group('AppBreakpoints', () {
    test('navigation rail engages at the medium boundary', () {
      expect(AppBreakpoints.useNavigationRail(599), isFalse);
      expect(AppBreakpoints.useNavigationRail(600), isTrue);
    });

    test('extended rail engages at the expanded boundary', () {
      expect(AppBreakpoints.useExtendedRail(1199), isFalse);
      expect(AppBreakpoints.useExtendedRail(1200), isTrue);
    });

    test('two-pane detail engages at the expanded boundary', () {
      expect(AppBreakpoints.useTwoPaneDetail(599), isFalse);
      expect(AppBreakpoints.useTwoPaneDetail(1199), isFalse);
      expect(AppBreakpoints.useTwoPaneDetail(1200), isTrue);
    });
  });

  group('TwoPane', () {
    testWidgets('renders primary and secondary with a divider', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MaterialApp(
          home: TwoPane(
            primary: Placeholder(key: Key('p')),
            secondary: Placeholder(key: Key('s')),
          ),
        ),
      );
      expect(find.byKey(const Key('p')), findsOneWidget);
      expect(find.byKey(const Key('s')), findsOneWidget);
      expect(find.byType(mui.VerticalDivider), findsOneWidget);
    });

    testWidgets('honours the default 55:45 split', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MaterialApp(
          home: TwoPane(
            primary: Placeholder(key: Key('p')),
            secondary: Placeholder(key: Key('s')),
          ),
        ),
      );
      // 1400 - 1px divider = 1399 usable; 55% ≈ 769, 45% ≈ 630.
      expect(
        tester.getSize(find.byKey(const Key('p'))).width,
        moreOrLessEquals(769.45, epsilon: 0.01),
      );
      expect(
        tester.getSize(find.byKey(const Key('s'))).width,
        moreOrLessEquals(629.55, epsilon: 0.01),
      );
    });
  });
}
