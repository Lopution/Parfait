import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/layout/app_breakpoints.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/layout/two_pane.dart';
import 'package:parfait/core/settings/app_settings.dart';

void main() {
  group('AppBreakpoints', () {
    test('a phone is a display under the medium boundary', () {
      expect(AppBreakpoints.isPhoneDisplay(const Size(411, 896)), isTrue);
      // A foldable's cover screen; its unfolded inner screen.
      expect(AppBreakpoints.isPhoneDisplay(const Size(360, 748)), isTrue);
      expect(AppBreakpoints.isPhoneDisplay(const Size(673, 841)), isFalse);
      // No display size reported: decided by the window alone.
      expect(AppBreakpoints.isPhoneDisplay(null), isFalse);
    });

    test('two-pane detail needs a landscape area at least medium wide', () {
      // A turned phone (the bar, no rail); a small tablet turned, less the
      // rail.
      expect(AppBreakpoints.useTwoPaneDetail(const Size(896, 411)), isTrue);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(919, 640)), isTrue);
      // Portrait tablet, unfolded foldable, landscape split screen.
      expect(AppBreakpoints.useTwoPaneDetail(const Size(720, 1280)), isFalse);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(620, 840)), isFalse);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(599, 300)), isFalse);
    });
  });

  group('FormFactor', () {
    FormFactor form(
      Size? display,
      TargetPlatform platform, [
      InterfaceForm choice = InterfaceForm.auto,
    ]) => FormFactor.resolve(
      display: display,
      platform: platform,
      choice: choice,
    );
    const phone = Size(411, 896);
    const tablet = Size(1280, 800);

    test('a phone, a touch screen or a PC, by display and platform', () {
      expect(form(phone, TargetPlatform.android), FormFactor.phone);
      expect(form(tablet, TargetPlatform.android), FormFactor.touch);
      expect(form(null, TargetPlatform.android), FormFactor.touch);
      expect(form(tablet, TargetPlatform.windows), FormFactor.pc);
      // A desktop asked for the touch shell (a Windows tablet).
      expect(
        form(tablet, TargetPlatform.windows, InterfaceForm.touch),
        FormFactor.touch,
      );
      // Only desktops offer the choice; one restored from a desktop's
      // backup does not turn a tablet into a PC.
      expect(
        form(tablet, TargetPlatform.android, InterfaceForm.pc),
        FormFactor.touch,
      );
    });

    test('the rail engages at the medium boundary, never on a phone', () {
      expect(FormFactor.touch.hasRail(599), isFalse);
      expect(FormFactor.touch.hasRail(600), isTrue);
      expect(FormFactor.pc.hasRail(600), isTrue);
      expect(FormFactor.phone.hasRail(1200), isFalse);
    });

    test("a PC's rail opens from extra-large until the user toggles it; "
        "a touch screen's never does", () {
      expect(FormFactor.pc.railExpanded(1599, choice: null), isFalse);
      expect(FormFactor.pc.railExpanded(1600, choice: null), isTrue);
      expect(FormFactor.pc.railExpanded(1920, choice: false), isFalse);
      expect(FormFactor.pc.railExpanded(800, choice: true), isTrue);
      expect(FormFactor.touch.railExpanded(1920, choice: true), isFalse);
    });
  });

  group('TwoPane', () {
    testWidgets('renders primary and secondary side by side', (tester) async {
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
      expect(
        tester.getRect(find.byKey(const Key('p'))).right,
        tester.getRect(find.byKey(const Key('s'))).left,
      );
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
