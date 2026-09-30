import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/widgets/follow_switch_button.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/user/follow_store.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/core/user/user_repository.dart';
import 'package:pixiv_func/features/profile/profile_header_delegate.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

Future<ProviderContainer> _world() async {
  installMemoryPreferences();
  final container = ProviderContainer(
    overrides: accountProviderOverrides(
      credentialStore: FakeCredentialStore(
        values: const {
          '100': Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
        },
      ),
      metadataRepository: FakeAccountMetadataRepository(
        accounts: const [Account(id: '100', userId: 100, name: 'me')],
        currentId: '100',
      ),
    ),
  );
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  required Widget home,
  Locale locale = const Locale('zh', 'CN'),
  double textScale = 1,
}) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
}

RenderParagraph _buttonParagraph(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(FollowSwitchButton),
        matching: find.byType(Text),
      ),
    );

/// Mounts a `ReplicaProfileHeaderDelegate` the same way `UserPage` does: the
/// expanded extent starts unset and is fed back from the identity block's
/// post-frame size report.
class _MeasuredHeader extends StatefulWidget {
  const _MeasuredHeader({required this.delegateFor});

  final ReplicaProfileHeaderDelegate Function(
    double? expandedExtent,
    ValueChanged<double> onMeasured,
  )
  delegateFor;

  @override
  State<_MeasuredHeader> createState() => _MeasuredHeaderState();
}

class _MeasuredHeaderState extends State<_MeasuredHeader> {
  double? _extent;

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: widget.delegateFor(_extent, (extent) {
        if (_extent == null || (extent - _extent!).abs() > 0.5) {
          setState(() => _extent = extent);
        }
      }),
    );
  }
}

void main() {
  testWidgets('a long label widens the button instead of truncating', (
    tester,
  ) async {
    final container = await _world();
    await _pump(
      tester,
      container,
      locale: const Locale('ru'),
      textScale: 2,
      home: const Scaffold(
        body: Center(
          child: FollowSwitchButton(userId: 42, userName: 'sample user'),
        ),
      ),
    );

    final paragraph = _buttonParagraph(tester);
    expect(paragraph.didExceedMaxLines, isFalse);
    // With softWrap: false a squeezed label reports a laid-out textSize
    // wider than its render box — equality means nothing was clipped.
    expect(
      paragraph.textSize.width,
      lessThanOrEqualTo(paragraph.size.width + 0.01),
    );
    expect(
      tester.getSize(find.byType(FollowSwitchButton)).width,
      greaterThan(116),
    );
  });

  testWidgets('a 1.3x label widens without scaling the text down', (
    tester,
  ) async {
    final container = await _world();
    await _pump(
      tester,
      container,
      locale: const Locale('ru'),
      textScale: 1.3,
      home: const Scaffold(
        body: Center(
          child: FollowSwitchButton(userId: 42, userName: 'sample user'),
        ),
      ),
    );

    final textFinder = find.descendant(
      of: find.byType(FollowSwitchButton),
      matching: find.byType(Text),
    );
    final paragraph = tester.renderObject<RenderParagraph>(textFinder);
    expect(
      tester.getSize(find.byType(FollowSwitchButton)).width,
      greaterThan(116),
    );
    // While the label fits, the FittedBox transform stays at identity: the
    // painted rect equals the laid-out text size at the real 1.3x metrics.
    expect(
      tester.getRect(textFinder).width,
      closeTo(paragraph.size.width, 0.5),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('short labels keep the minimum size', (tester) async {
    final container = await _world();
    await _pump(
      tester,
      container,
      home: const Scaffold(
        body: Center(
          child: FollowSwitchButton(userId: 42, userName: 'sample user'),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(FollowSwitchButton)),
      const Size(116, 42),
    );

    await _pump(
      tester,
      container,
      home: const Scaffold(
        body: Center(
          child: FollowSwitchButton(
            userId: 42,
            userName: 'sample user',
            compact: true,
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(FollowSwitchButton)), const Size(96, 36));
  });

  testWidgets('the pending spinner keeps the minimum size', (tester) async {
    final container = await _world();
    await _pump(
      tester,
      container,
      home: const Scaffold(
        body: Center(
          child: FollowSwitchButton(userId: 42, userName: 'sample user'),
        ),
      ),
    );

    container.read(followStoreProvider.notifier).beginAdd(42);
    await tester.pump();

    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(
      tester.getSize(find.byType(FollowSwitchButton)),
      const Size(116, 42),
    );
  });

  testWidgets('call sites lay out without overflow at ru + 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = await _world();

    // Profile header (profile_header_delegate.dart): the button sits in a
    // Flexible next to the share action, so a wider label squeezes the row
    // instead of overflowing it.
    await _pump(
      tester,
      container,
      locale: const Locale('ru'),
      textScale: 2,
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            _MeasuredHeader(
              delegateFor: (extent, onMeasured) => ReplicaProfileHeaderDelegate(
                user: const UserEntity(id: 42, name: 'u', account: 'u'),
                isMe: false,
                selectedTabIndex: 0,
                showRestrictSelector: false,
                restrict: UserRestrict.public,
                onRestrictChanged: (_) {},
                onShare: (_) {},
                onToggleFollow: () {},
                expandedExtent: extent,
                onExpandedExtentMeasured: onMeasured,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 2000)),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(FollowSwitchButton), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(_buttonParagraph(tester).didExceedMaxLines, isFalse);

    // Both user lists (profile_user_feed.dart, search_result_page.dart)
    // cap the ListTile's trailing slot at half the row: the title keeps a
    // lane, and the label scales down instead of overflowing the tile.
    for (final subtitle in ['@sample', 'u: sample']) {
      await _pump(
        tester,
        container,
        locale: const Locale('ru'),
        textScale: 2,
        home: Scaffold(
          body: Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: ListTile(
              leading: const SizedBox(width: 52, height: 52),
              title: const Text(
                'sample user',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(subtitle),
              trailing: LayoutBuilder(
                builder: (context, constraints) => ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.5,
                  ),
                  child: const FollowSwitchButton(
                    userId: 42,
                    userName: 'sample user',
                    userAccount: 'sample',
                    compact: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'tile "$subtitle"');
      expect(
        tester.getSize(find.text('sample user')).width,
        greaterThan(0),
        reason: 'tile "$subtitle" title lane',
      );
      expect(
        tester.getSize(find.byType(FollowSwitchButton)).width,
        lessThanOrEqualTo(
          tester.getSize(find.byType(ListTile)).width * 0.5 + 0.01,
        ),
        reason: 'tile "$subtitle" button cap',
      );
      expect(
        _buttonParagraph(tester).didExceedMaxLines,
        isFalse,
        reason: 'tile "$subtitle" label',
      );
    }
  });
}
