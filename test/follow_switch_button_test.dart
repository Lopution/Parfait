import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/core/user/follow_models.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/user/follow_store.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/prompt_host.dart';
import 'helpers/profile_world.dart';
import 'helpers/localized_app.dart';

Future<ProviderContainer> _world({required FollowApi follows}) =>
    signedInApiContainer(
      PixivApi(follows.routes).client,
      account: const Account(id: '100', userId: 100, name: 'me'),
    );

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  required Widget home,
  Locale locale = const Locale('zh', 'CN'),
  double textScale = 1,
}) {
  return tester.pumpWidget(
    localizedApp(
      container: container,
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
  );
}

void main() {
  testWidgets('the button flips before the server answers and rolls back on '
      'failure', (tester) async {
    final follows = FollowApi();
    final container = await _world(follows: follows);
    await _pump(
      tester,
      container,
      home: const Scaffold(
        body: Center(child: FollowSwitchButton(userId: 7, userName: 'u')),
      ),
    );
    final gate = follows.gate = Completer<void>();
    follows.failure = failing(400);

    await tester.tap(find.byType(FollowSwitchButton));
    await tester.pump();
    expect(find.text('已关注'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(
      tester.getSize(find.byType(FollowSwitchButton)),
      const Size(116, 48),
    );

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('关注'), findsOneWidget);
    expect(find.textContaining('关注操作失败'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('the sheet offers direct actions for each follow state', (
    tester,
  ) async {
    final follows = FollowApi();
    final container = await _world(follows: follows);
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    await _pump(
      tester,
      container,
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: shown,
            builder: (_, show, _) => show
                ? const FollowSwitchButton(userId: 7, userName: 'u')
                : const SizedBox(),
          ),
        ),
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
    expect(follows.requests, ['add:7:private']);
    expect(restrict(), FollowRestrict.private);

    // Followed privately: make public or unfollow.
    await openSheet();
    expect(action('改为私密关注'), findsNothing);
    expect(action('取消关注'), findsOneWidget);
    await tester.tap(action('改为公开关注'));
    await tester.pumpAndSettle();
    expect(follows.requests.last, 'add:7:public');
    expect(restrict(), FollowRestrict.public);

    // Followed publicly: make private or unfollow — with Undo.
    await openSheet();
    expect(action('改为公开关注'), findsNothing);
    expect(action('改为私密关注'), findsOneWidget);
    await tester.tap(action('取消关注'));
    await tester.pumpAndSettle();
    expect(follows.requests.last, 'delete:7');
    await tester.tap(promptAction('撤销'));
    await tester.pumpAndSettle();
    expect(follows.requests.last, 'add:7:public');
    expect(container.read(followStoreProvider)[7]?.followed, isTrue);

    // A refresh takes the button away under the open sheet: the pick
    // still goes out, and its failure still says why.
    await openSheet();
    shown.value = false;
    await tester.pump();
    follows.failure = failing(400);
    await tester.tap(action('改为私密关注'));
    await tester.pumpAndSettle();
    expect(follows.requests.last, 'add:7:private');
    expect(find.textContaining('关注操作失败'), findsOneWidget);
  });
}
