import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/window/desktop_workspace_tabs.dart';

import '../helpers/leak_tracking.dart';
import '../review/review_support.dart';

void main() {
  ignoreOctoImageFades();

  group('In-app real-shell E2E', () {
    testWidgets(
      'desktop secondary workspace tab inherits real GoRouter inside AppChrome',
      (tester) async {
        // Reliability P0 eda6c80e: secondary workspace tabs sit inside
        // DesktopWorkspaceTabHost above Router's child and must still resolve
        // GoRouter.of(context) for in-tab navigation.
        final desktop = reviewDevices['desktop']!;
        late final ReviewWorld world;
        await tester.runAsync(() async {
          world = await ReviewWorld.open(
            ReviewSetup(platformCaps: desktop.platformCaps),
          );
        });
        late final GoRouter router;
        await reviewScene(
          tester,
          semantics: false,
          onDispose: world.container.dispose,
          () async {
            router = await pumpReviewApp(tester, world: world, device: desktop);
            await settleReview(tester);

            final tabs = DesktopWorkspaceTabsController.active;
            expect(tabs, isNotNull);

            GoRouter? resolvedFromTab;
            Object? lookupError;
            tabs!.openBackgroundTab(
              title: 'Detail Tab',
              icon: AppIcons.illust,
              builder: (tabContext) => Builder(
                builder: (innerContext) {
                  try {
                    resolvedFromTab = GoRouter.of(innerContext);
                  } catch (e) {
                    lookupError = e;
                  }
                  return const SizedBox.shrink();
                },
              ),
            );
            tabs.selectTab(1);
            await tester.pump();
            await tester.pump();

            expect(lookupError, isNull);
            expect(resolvedFromTab, same(router));
          },
        );
      },
    );
  });
}
