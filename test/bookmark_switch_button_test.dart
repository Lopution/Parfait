import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/bookmark/bookmark_repository.dart';
import 'package:pixiv_func/core/bookmark/bookmark_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/features/bookmark/bookmark_switch_button.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _StubAccountStore extends AccountStore {
  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [Account(id: '100', userId: 100, name: 'a')],
    currentId: '100',
  );
}

class _RecordingRepository implements BookmarkRepository {
  final List<(int id, String restrict)> adds = [];
  final List<int> deletes = [];
  Object? addError;

  @override
  Future<void> addIllust(
    int id,
    BookmarkRestrict restrict, {
    CancelToken? cancelToken,
  }) async {
    final error = addError;
    if (error != null) throw error;
    adds.add((id, restrict.name));
  }

  @override
  Future<void> deleteIllust(int id, {CancelToken? cancelToken}) async {
    deletes.add(id);
  }
}

Future<(ProviderContainer, _RecordingRepository)> _pump(
  WidgetTester tester, {
  Widget? child,
}) async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final repository = _RecordingRepository();
  final container = ProviderContainer(
    overrides: [
      accountStoreProvider.overrideWith(_StubAccountStore.new),
      bookmarkRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child:
                child ??
                const BookmarkSwitchButton(illustId: 1, title: 'work 1'),
          ),
        ),
      ),
    ),
  );
  // Mutation envelopes require a resolved authenticated boundary.  Wait for
  // the async account fixture before exercising the button; a single frame
  // only starts AccountStore.build().
  await container.read(accountStoreProvider.future);
  await tester.pumpAndSettle();
  return (container, repository);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('unknown state shows outline heart; tap sends public add (R3)', (
    tester,
  ) async {
    final (container, repository) = await _pump(tester);

    expect(find.byIcon(Icons.favorite_outline_sharp), findsOneWidget);

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pump();

    expect(repository.adds, hasLength(1));
    expect(repository.adds.single.$1, 1);
    expect(repository.adds.single.$2, 'public');
    expect(
      container
          .read(bookmarkStoreProvider)[const BookmarkKey(
            BookmarkEntityType.illust,
            1,
          )]!
          .bookmarked,
      isTrue,
    );
    await tester.pump();
    expect(find.byIcon(Icons.favorite_sharp), findsOneWidget);
  });

  testWidgets('pending phase shows a CupertinoActivityIndicator (R4)', (
    tester,
  ) async {
    final (container, _) = await _pump(tester);
    const key = BookmarkKey(BookmarkEntityType.illust, 1);

    container
        .read(bookmarkStoreProvider.notifier)
        .beginAdd(key, BookmarkRestrict.public);
    await tester.pump();

    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.byIcon(Icons.favorite_outline_sharp), findsNothing);
  });

  testWidgets('bookmarked long press opens no sheet (R6)', (tester) async {
    final (container, _) = await _pump(tester);
    const key = BookmarkKey(BookmarkEntityType.illust, 1);
    container
        .read(bookmarkStoreProvider.notifier)
        .observeRemote(key, bookmarked: true, snapshotRevision: 0);
    await tester.pump();

    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    expect(find.text('收藏插画'), findsNothing);
    expect(find.text('确定'), findsNothing);
  });

  testWidgets('unbookmarked long press opens the restrict sheet; confirm '
      'sends the chosen restrict (R3)', (tester) async {
    final (_, repository) = await _pump(tester);

    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    expect(find.text('收藏插画'), findsOneWidget);
    expect(find.text('work 1'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('公开'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);

    // Choose 私密, then confirm.
    await tester.tap(find.text('公开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私密').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(repository.adds, hasLength(1));
    expect(repository.adds.single.$2, 'private');
  });

  testWidgets('failure surfaces a snackbar and restores the icon (R5)', (
    tester,
  ) async {
    final (_, repository) = await _pump(tester);
    repository.addError = StateError('boom');

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('收藏操作失败'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_outline_sharp), findsOneWidget);
  });

  testWidgets('placeholder renders nothing', (tester) async {
    await _pump(
      tester,
      child: const BookmarkSwitchButton(
        illustId: 1,
        title: 'work 1',
        isPlaceholder: true,
      ),
    );
    expect(find.byIcon(Icons.favorite_outline_sharp), findsNothing);
    expect(find.byIcon(Icons.favorite_sharp), findsNothing);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  });
}
