import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/bookmark_switch_button.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/bookmark/bookmark_repository.dart';
import 'package:parfait/core/bookmark/bookmark_store.dart';
import 'package:parfait/core/user/follow_models.dart';
import 'package:parfait/core/user/follow_store.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/bookmark_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/profile_world.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

const _bookmarkKey = BookmarkKey(BookmarkEntityType.illust, 1);

/// [child] on a route pushed over a home Scaffold, so popping it leaves the
/// app's messenger — and the snackbar — in place.
Future<void> _pumpPushed(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: promptHostBuilder,
        navigatorKey: navigator,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: appLocalizationsDelegates,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
  navigator.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _closePage(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator)).pop();
  await tester.pumpAndSettle();
}

Finder get _undo => promptAction('撤销');

void main() {
  testWidgets('a private, tagged bookmark comes back private with its tags', (
    tester,
  ) async {
    installMemoryPreferences();
    final repository = RecordingBookmarkRepository()
      ..detail = const BookmarkDetail(
        isBookmarked: true,
        restrict: BookmarkRestrict.private,
        tags: [BookmarkTagFacet(name: 'kept', isRegistered: true)],
      );
    final container = ProviderContainer(
      overrides: [
        accountStoreProvider.overrideWith(StubAccountStore.new),
        bookmarkRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    await container.read(accountStoreProvider.future);
    container
        .read(bookmarkStoreProvider.notifier)
        .observeRemote(
          _bookmarkKey,
          bookmarked: true,
          restrict: BookmarkRestrict.private,
        );
    await _pumpPushed(
      tester,
      container,
      const BookmarkSwitchButton(illustId: 1, title: 'work 1'),
    );

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();
    expect(repository.deletes, [1]);
    expect(find.text('已取消收藏'), findsOneWidget);

    // Undo still lands after the page that offered it is gone.
    await _closePage(tester);
    await tester.tap(_undo);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final (id, restrict, tags) = repository.adds.single;
    expect((id, restrict), (1, 'private'));
    expect(tags, ['kept']);
    final entry = container.read(bookmarkStoreProvider)[_bookmarkKey]!;
    expect(entry.bookmarked, isTrue);
    expect(entry.restrict, BookmarkRestrict.private);
    expect(entry.tags, ['kept']);
  });

  testWidgets('a private follow comes back private', (tester) async {
    final follows = FakeFollowRepository()
      ..remoteRestrict = FollowRestrict.private;
    final container = await makeProfileWorld(follows: follows);
    container
        .read(followStoreProvider.notifier)
        .observeRemote(42, followed: true);
    await _pumpPushed(
      tester,
      container,
      const FollowSwitchButton(userId: 42, userName: 'author'),
    );

    await tester.tap(find.byType(FollowSwitchButton));
    await tester.pumpAndSettle();
    expect(find.text('已取消关注'), findsOneWidget);
    // No confirmation step: the unfollow already landed (D5).
    expect(find.byType(AlertDialog), findsNothing);

    await _closePage(tester);
    await tester.tap(_undo);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(follows.requests, ['restrict:42', 'delete:42', 'add:42:private']);
    final entry = container.read(followStoreProvider)[42]!;
    expect(entry.followed, isTrue);
    expect(entry.restrict, FollowRestrict.private);
  });

  testWidgets('without the original visibility there is no Undo', (
    tester,
  ) async {
    final follows = FakeFollowRepository()..remoteRestrict = null;
    final container = await makeProfileWorld(follows: follows);
    container
        .read(followStoreProvider.notifier)
        .observeRemote(42, followed: true);
    await _pumpPushed(
      tester,
      container,
      const FollowSwitchButton(userId: 42, userName: 'author'),
    );

    await tester.tap(find.byType(FollowSwitchButton));
    await tester.pumpAndSettle();

    expect(follows.requests, ['restrict:42', 'delete:42']);
    expect(container.read(followStoreProvider)[42]!.followed, isFalse);
    expect(shownPrompt, findsNothing);
  });
}
