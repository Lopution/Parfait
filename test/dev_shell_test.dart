import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/dev_shell/dev_shell.dart';
import 'package:parfait/app/layout/window_layout_spec.dart';
import 'package:parfait/app/window/desktop_title_bar.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

class _StatefulProbe extends StatefulWidget {
  const _StatefulProbe();

  @override
  State<_StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<_StatefulProbe> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    final spec = WindowLayoutSpec.of(context);
    final env = WindowEnvironmentOverride.maybeOf(context);
    return DesktopWindowFrame(
      child: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'c=$_count|p=${spec.targetPlatform.name}|'
                'f=${spec.posture.name}|w=${spec.windowSize.width.toInt()}|'
                'dpr=${spec.devicePixelRatio}|m=${spec.inputModality.name}|'
                'lights=${env?.showSimulatedTrafficLights ?? false}',
                key: const ValueKey('dev-shell-probe-readout'),
              ),
              TextButton(
                key: const ValueKey('dev-shell-probe-inc'),
                onPressed: () => setState(() => _count++),
                child: const Text('inc'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'DevShellHost hot-switches 5 OS platforms, fold postures, DPR, modality and pill collapse while keeping child State',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = DevShellController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DevShellHost(
              controller: controller,
              child: const _StatefulProbe(),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('dev-shell-probe-inc')));
      await tester.pump();
      expect(find.textContaining('c=1|'), findsOneWidget);

      controller.setPlatform(DevShellPlatform.android);
      controller.setViewport(DevShellViewportPreset.phone);
      await tester.pump();
      expect(
        find.text('c=1|p=android|f=flat|w=390|dpr=3.0|m=touch|lights=false'),
        findsOneWidget,
      );

      controller.setPlatform(DevShellPlatform.ios);
      controller.setViewport(DevShellViewportPreset.iphone);
      await tester.pump();
      expect(
        find.text('c=1|p=iOS|f=flat|w=393|dpr=3.0|m=touch|lights=false'),
        findsOneWidget,
      );

      controller.setViewport(DevShellViewportPreset.ipad);
      controller.toggleCreaseOverlay();
      controller.setViewport(DevShellViewportPreset.foldableBook);
      controller.setPlatform(DevShellPlatform.android);
      await tester.pump();
      expect(
        find.text('c=1|p=android|f=book|w=884|dpr=2.5|m=touch|lights=false'),
        findsOneWidget,
      );
      expect(find.byType(CustomPaint), findsWidgets);

      controller.setViewport(DevShellViewportPreset.foldableTabletop);
      await tester.pump();
      expect(find.textContaining('f=tabletop|'), findsOneWidget);

      controller.setPlatform(DevShellPlatform.windows);
      controller.setViewport(DevShellViewportPreset.desktop);
      await tester.pump();
      expect(
        find.text('c=1|p=windows|f=flat|w=1280|dpr=1.5|m=pointer|lights=false'),
        findsOneWidget,
      );

      controller.setPlatform(DevShellPlatform.macos);
      await tester.pump();
      expect(
        find.text('c=1|p=macOS|f=flat|w=1280|dpr=1.5|m=pointer|lights=true'),
        findsOneWidget,
      );
      expect(find.byType(SimulatedMacTrafficLights), findsOneWidget);

      controller.setPlatform(DevShellPlatform.linux);
      controller.cycleDpr();
      controller.cycleModality();
      await tester.pump();
      expect(
        find.text('c=1|p=linux|f=flat|w=1280|dpr=1.0|m=touch|lights=false'),
        findsOneWidget,
      );

      // Collapse into floating pill and expand again via toolbar button.
      await tester.tap(find.byKey(const ValueKey('dev-shell-collapse-btn')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('dev-shell-floating-pill')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('dev-shell-platform-menu')),
        findsNothing,
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('dev-shell-floating-pill')),
          matching: find.byIcon(Icons.tune_outlined),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('dev-shell-platform-menu')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('dev-shell-probe-inc')));
      await tester.pump();
      expect(find.textContaining('c=2|'), findsOneWidget);
    },
  );

  testWidgets(
    'DevShellHost works inside MaterialApp.builder above Navigator Overlay',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = DevShellController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              DevShellHost(controller: controller, child: child!),
          home: const _StatefulProbe(),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('dev-shell-platform-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Windows'));
      await tester.pumpAndSettle();
      expect(controller.platform, DevShellPlatform.windows);
      expect(
        find.text('c=0|p=windows|f=flat|w=1400|dpr=3.0|m=pointer|lights=false'),
        findsOneWidget,
      );
    },
  );
}
