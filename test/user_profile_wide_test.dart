import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/content_widths.dart';
import 'package:parfait/app/navigation/route_facade.dart';
import 'package:parfait/app/widgets/expandable_text.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/app/window/desktop_command_bar.dart';
import 'package:parfait/core/user/follow_store.dart';
import 'package:parfait/features/profile/profile_skeleton.dart';
import 'package:parfait/features/profile/user_page.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/profile_world.dart';
import 'helpers/prompt_host.dart';
import 'helpers/view_size.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/icons/ui_icons.dart';

/// The profile header on a wide window, away from the phone-sized cases in
/// user_profile_test.dart (which also keeps that file under the size limit).
void main() {
  testWidgets(
    'wide profile aligns two-band header margins with right actions and bio cap',
    (tester) async {
      setViewSize(tester, const Size(1920, 1080));
      final container = await makeProfileWorld(
        users: UserApi(
          works: [
            for (var id = 1; id <= 6; id++)
              illustJson(id, width: 300, height: 400),
          ],
          detail: sampleUser(42).copyWith(
            totalIllusts: 6,
            totalFollowUsers: 50,
            totalMyPixivUsers: 5,
            comment: 'bio of user 42',
            hasDetail: true,
          ),
        ),
      );
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: const UserPage(userId: 42),
        ),
      );
      await tester.pumpAndSettle();

      // Band 1 spans the full 16dp header margin so primary/share actions align
      // flush with the right edge, while Band 2 flushes inline stats and a
      // ContentWidths.management-capped bio with the 16dp avatar left edge.
      expect(find.byKey(const ValueKey('profile-wide-split')), findsOneWidget);
      final avatar = tester.getRect(
        find.byKey(const ValueKey('profile-expanded-avatar')),
      );
      final name = tester.getRect(
        find.byKey(const ValueKey('profile-expanded-name')),
      );
      final share = tester.getRect(find.byIcon(AppIcons.share).first);
      final follow = tester.getRect(find.byType(FollowSwitchButton));
      final stat = tester.getRect(
        find.byKey(const ValueKey('profile-stat-following-header')),
      );
      final statFigure = tester.getRect(find.text('50'));
      final bio = tester.getRect(
        find.byKey(const ValueKey('profile-wide-bio')),
      );
      expect(avatar.left, 16);
      expect(follow.left, greaterThanOrEqualTo(name.right));
      expect(follow.left, lessThan(share.left));
      expect((follow.center.dy - name.center.dy).abs(), lessThan(48));
      expect(share.right, closeTo(1920 - 16, 0.5));
      expect(stat.top, greaterThanOrEqualTo(avatar.bottom));
      expect(statFigure.left, closeTo(avatar.left, 0.5));
      expect(bio.left, closeTo(avatar.left, 0.5));
      expect(bio.width, lessThanOrEqualTo(ContentWidths.management));
      expect(
        tester.getRect(find.byKey(const ValueKey('profile-tabs'))).width,
        1920,
      );
    },
  );

  testWidgets('profile wide split activates only at >= 840x480', (
    tester,
  ) async {
    setViewSize(tester, const Size(1024, 768));
    final container = await makeProfileWorld(
      users: UserApi(
        works: [
          for (var id = 1; id <= 6; id++)
            illustJson(id, width: 300, height: 400),
        ],
        detail: sampleUser(42).copyWith(totalIllusts: 6, hasDetail: true),
      ),
    );
    await tester.pumpWidget(
      localizedApp(
        container: container,
        builder: promptHostBuilder,
        home: const UserPage(userId: 42),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-wide-split')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-tabs')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-nested-scroll')), findsNothing);

    setViewSize(tester, const Size(750, 900));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-wide-split')), findsNothing);
    expect(find.byKey(const ValueKey('profile-nested-scroll')), findsOneWidget);

    setViewSize(tester, const Size(900, 440));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-wide-split')), findsNothing);
    expect(find.byKey(const ValueKey('profile-nested-scroll')), findsOneWidget);
  });

  testWidgets(
    'wide profile skeleton avoids duplicate back button and empty works hide total',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final users = UserApi(
        detail: sampleUser(42).copyWith(totalIllusts: 120, hasDetail: true),
        works: const [],
      )..detailGate = gate;
      final container = await makeProfileWorld(users: users);
      await tester.pumpWidget(
        DesktopCommandBarScope(
          active: true,
          child: localizedApp(
            container: container,
            builder: promptHostBuilder,
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ProfileSkeleton), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-wide-split')), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(FeedEmpty), findsOneWidget);
      expect(find.textContaining('共 '), findsNothing);
    },
  );

  testWidgets(
    'wide desktop collapsed sticky bar shows artist name and folds primary & follow-visibility actions into overflow',
    (tester) async {
      setViewSize(tester, const Size(1280, 640));
      final container = await makeProfileWorld(
        users: UserApi(
          works: [
            for (var id = 1; id <= 24; id++)
              illustJson(id, width: 300, height: 400),
          ],
          detail: sampleUser(42).copyWith(
            totalIllusts: 24,
            isFollowed: true,
            comment: 'Line 1\nLine 2\nLine 3\nLine 4 extra bio text',
            hasDetail: true,
          ),
        ),
      );
      container
          .read(followStoreProvider.notifier)
          .observeRemote(42, followed: true);
      await tester.pumpWidget(
        DesktopCommandBarScope(
          active: true,
          child: localizedApp(
            container: container,
            builder: promptHostBuilder,
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ExpandableText), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-wide-collapsed-name')),
        findsNothing,
      );

      // Scroll past the banner so Band 1 scrolls offscreen.
      await tester.drag(
        find.byKey(const ValueKey('profile-wide-scroll')),
        const Offset(0, -320),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-wide-collapsed-name')),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(UiIcons.more));
      await tester.pumpAndSettle();
      expect(find.text('分享用户'), findsOneWidget);
      expect(find.text('取消关注'), findsOneWidget);
      expect(find.text('切换公开/私密关注'), findsOneWidget);
    },
  );

  testWidgets(
    'own profile exposes About tab, ExpandableText bio, and honors MeTab.myPixiv',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      final container = await makeProfileWorld(
        users: UserApi(
          detail: sampleUser(100).copyWith(
            comment: 'My own long bio',
            totalMyPixivUsers: 3,
            hasDetail: true,
          ),
        ),
      );
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: MePage(initialTab: MeTab.myPixiv, onEditProfile: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('关于'), findsOneWidget);
      expect(find.byType(ExpandableText), findsOneWidget);
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.controller!.index, 3);
    },
  );
}
