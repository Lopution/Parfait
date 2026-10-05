import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/haptics/app_haptics.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/user/follow_models.dart';
import 'package:parfait/core/user/follow_repository.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/user/follow_store.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:parfait/features/profile/profile_header_delegate.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/fake_account.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/test_preferences.dart';

/// Network boundary stand-in; [error] makes the next mutation fail.
class _FakeFollowRepository implements FollowRepository {
  final calls = <String>[];
  Object? error;

  @override
  Future<void> add(
    int userId, {
    FollowRestrict restrict = FollowRestrict.public,
    CancelToken? cancelToken,
  }) async {
    if (error case final error?) throw error;
    calls.add('add $userId ${restrict.name}');
  }

  @override
  Future<void> delete(int userId, {CancelToken? cancelToken}) async {
    if (error case final error?) throw error;
    calls.add('delete $userId');
  }

  @override
  Future<FollowRestrict?> fetchRestrict(
    int userId, {
    CancelToken? cancelToken,
  }) async {
    calls.add('restrict $userId');
    return FollowRestrict.public;
  }
}

Future<ProviderContainer> _world({FollowRepository? follows}) async {
  installMemoryPreferences();
  final container = ProviderContainer(
    overrides: [
      if (follows != null) followRepositoryProvider.overrideWithValue(follows),
      ...accountProviderOverrides(
        credentialStore: FakeCredentialStore(
          values: const {
            '100': Credential(
              accessToken: 'access-1',
              refreshToken: 'refresh-1',
            ),
          },
        ),
        metadataRepository: FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'me')],
          currentId: '100',
        ),
      ),
    ],
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

/// The label is whole, or — scaled to LabelFit's floor and still too wide
/// (FlutterTest's square glyphs at ru + 2x) — ellipsized with its full text
/// in a tooltip.
void _expectLabelReadable(WidgetTester tester, {String? reason}) {
  final paragraph = _buttonParagraph(tester);
  if (!paragraph.didExceedMaxLines) return;
  final text = paragraph.text.toPlainText();
  expect(
    find.descendant(
      of: find.byType(FollowSwitchButton),
      matching: find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == text,
      ),
    ),
    findsOneWidget,
    reason: reason,
  );
}

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
  testWidgets('haptics follow the settled outcome', (tester) async {
    final haptics = recordHaptics();
    final follows = _FakeFollowRepository();
    final container = await _world(follows: follows);
    await _pump(
      tester,
      container,
      home: const Scaffold(
        body: Center(child: FollowSwitchButton(userId: 7, userName: 'u')),
      ),
    );

    await tester.tap(find.byType(FollowSwitchButton));
    await tester.pumpAndSettle();
    expect(follows.calls, ['add 7 public']);
    expect(haptics.roles, [HapticRole.select]);

    // The throttle reads the wall clock; let the light lane re-arm.
    await tester.runAsync(() => Future<void>.delayed(AppHaptics.lightInterval));
    await tester.tap(find.byType(FollowSwitchButton));
    await tester.pumpAndSettle();
    expect(follows.calls, ['add 7 public', 'delete 7']);
    expect(haptics.roles, [HapticRole.select, HapticRole.select]);

    follows.error = StateError('boom');
    await tester.tap(find.byType(FollowSwitchButton));
    await tester.pumpAndSettle();
    expect(haptics.roles, [
      HapticRole.select,
      HapticRole.select,
      HapticRole.error,
    ]);
  });

  testWidgets('long press opens the follow sheet once', (tester) async {
    final haptics = recordHaptics();
    final follows = _FakeFollowRepository();
    final container = await _world(follows: follows);
    await _pump(
      tester,
      container,
      home: const Scaffold(
        body: Center(child: FollowSwitchButton(userId: 7, userName: 'u')),
      ),
    );

    await tester.longPress(find.byType(FollowSwitchButton));
    await tester.pumpAndSettle();
    expect(haptics.roles, [HapticRole.longPress]);
    // The framework's own long-press vibration is off.
    final button = tester.widget<OutlinedButton>(
      find.descendant(
        of: find.byType(FollowSwitchButton),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.style?.enableFeedback, isFalse);
  });

  testWidgets('the sheet offers direct actions for each follow state', (
    tester,
  ) async {
    final follows = _FakeFollowRepository();
    final container = await _world(follows: follows);
    await _pump(
      tester,
      container,
      home: const Scaffold(
        body: Center(child: FollowSwitchButton(userId: 7, userName: 'u')),
      ),
    );
    Future<void> openSheet() async {
      await tester.longPress(find.byType(FollowSwitchButton));
      await tester.pumpAndSettle();
    }

    Finder action(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate(
        (widget) => widget is FilledButton || widget is OutlinedButton,
      ),
    );
    FollowRestrict? restrict() =>
        container.read(followStoreProvider)[7]?.restrict;

    // Not followed: follow publicly (primary) or privately.
    await openSheet();
    expect(find.byType(FilledButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.text('公开关注'),
      ),
      findsOneWidget,
    );
    expect(action('私密关注'), findsOneWidget);
    expect(find.text('取消关注'), findsNothing);
    for (final button in [action('公开关注'), action('私密关注')]) {
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    }
    await tester.tap(action('私密关注'));
    await tester.pumpAndSettle();
    expect(follows.calls, ['add 7 private']);
    expect(restrict(), FollowRestrict.private);

    // Followed privately: make public or unfollow.
    await openSheet();
    expect(action('改为私密关注'), findsNothing);
    expect(action('取消关注'), findsOneWidget);
    await tester.tap(action('改为公开关注'));
    await tester.pumpAndSettle();
    expect(follows.calls.last, 'add 7 public');
    expect(restrict(), FollowRestrict.public);

    // Followed publicly: make private or unfollow — with Undo.
    await openSheet();
    expect(action('改为公开关注'), findsNothing);
    expect(action('改为私密关注'), findsOneWidget);
    await tester.tap(action('取消关注'));
    await tester.pumpAndSettle();
    expect(follows.calls.last, 'delete 7');
    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pumpAndSettle();
    expect(follows.calls.last, 'add 7 public');
    expect(container.read(followStoreProvider)[7]?.followed, isTrue);
  });

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
    _expectLabelReadable(tester);

    // Both user lists (profile_user_feed.dart, search_result_page.dart)
    // cap the ListTile's trailing slot at half the row: the title keeps a
    // lane, and the label scales down (then ellipsizes) instead of
    // overflowing the tile.
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
      _expectLabelReadable(tester, reason: 'tile "$subtitle" label');
    }
  });
}
