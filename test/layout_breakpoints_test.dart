import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:parfait/app/layout/app_breakpoints.dart';
import 'package:parfait/app/layout/two_pane.dart';

void main() {
  group('AppBreakpoints', () {
    test('navigation rail engages at the medium boundary', () {
      expect(AppBreakpoints.useNavigationRail(599), isFalse);
      expect(AppBreakpoints.useNavigationRail(600), isTrue);
    });

    test('extended rail waits for the extra-large boundary', () {
      expect(AppBreakpoints.useExtendedRail(1599), isFalse);
      expect(AppBreakpoints.useExtendedRail(1600), isTrue);
    });

    test('two-pane detail needs a landscape area at least medium wide', () {
      // A turned phone less the rail; a small landscape tablet.
      expect(AppBreakpoints.useTwoPaneDetail(const Size(815, 411)), isTrue);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(919, 640)), isTrue);
      // Portrait tablet, unfolded foldable, landscape split screen.
      expect(AppBreakpoints.useTwoPaneDetail(const Size(720, 1280)), isFalse);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(620, 840)), isFalse);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(599, 300)), isFalse);
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

    testWidgets('the secondary column stays between its bounds', (
      tester,
    ) async {
      Future<double> secondaryWidth(double width) async {
        await tester.binding.setSurfaceSize(Size(width, 600));
        await tester.pumpWidget(
          const MaterialApp(
            home: TwoPane(
              primary: Placeholder(key: Key('p')),
              secondary: Placeholder(key: Key('s')),
            ),
          ),
        );
        return tester.getSize(find.byKey(const Key('s'))).width;
      }

      addTearDown(() => tester.binding.setSurfaceSize(null));
      expect(await secondaryWidth(815), 320);
      expect(await secondaryWidth(1000), moreOrLessEquals(380));
      expect(await secondaryWidth(1440), 480);
    });
  });
}
