import 'dart:async';

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
import 'package:parfait/features/profile/profile_header_delegate.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/fake_account.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

/// Network boundary stand-in; [error] makes the next mutation fail and
/// [gate] holds mutations in flight.
class _FakeFollowRepository implements FollowRepository {
  final calls = <String>[];
  Object? error;
  Completer<void>? gate;

  @override
  Future<void> add(
    int userId, {
    FollowRestrict restrict = FollowRestrict.public,
    CancelToken? cancelToken,
  }) async {
    await gate?.future;
    if (error case final error?) throw error;
    calls.add('add $userId ${restrict.name}');
  }

  @override
  Future<void> delete(int userId, {CancelToken? cancelToken}) async {
    await gate?.future;
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
        builder: (context, child) => promptHostBuilder(
          context,
          MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        home: home,
      ),
    ),
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
  testWidgets('haptics play on the tap; a failure adds an error', (
    tester,
  ) async {
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

    await tester.runAsync(() => Future<void>.delayed(AppHaptics.lightInterval));
    follows.error = StateError('boom');
    await tester.tap(find.byType(FollowSwitchButton));
    await tester.pumpAndSettle();
    expect(haptics.roles, [
      HapticRole.select,
      HapticRole.select,
      HapticRole.select,
      HapticRole.error,
    ]);
  });

  testWidgets('the button flips before the server answers and rolls back on '
      'failure', (tester) async {
    final follows = _FakeFollowRepository();
    final container = await _world(follows: follows);
    await _pump(
      tester,
      container,
      home: const Scaffold(
        body: Center(child: FollowSwitchButton(userId: 7, userName: 'u')),
      ),
    );
    final gate = follows.gate = Completer<void>();
    follows.error = StateError('boom');

    await tester.tap(find.byType(FollowSwitchButton));
    await tester.pump();
    expect(find.text('已关注'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(
      tester.getSize(find.byType(FollowSwitchButton)),
      const Size(116, 42),
    );

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('关注'), findsOneWidget);
    expect(find.textContaining('关注操作失败'), findsOneWidget);
    await tester.pumpAndSettle();
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
    await tester.tap(promptAction('撤销'));
    await tester.pumpAndSettle();
    expect(follows.calls.last, 'add 7 public');
    expect(container.read(followStoreProvider)[7]?.followed, isTrue);
  });
}
