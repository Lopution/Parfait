import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/bookmark/bookmark_repository.dart';
import 'package:pixiv_func/core/bookmark/bookmark_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/app/widgets/bookmark_switch_button.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

class _StubAccountStore extends AccountStore {
  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [Account(id: '100', userId: 100, name: 'a')],
    currentId: '100',
  );
}

class _RecordingRepository implements BookmarkRepository {
  final List<(int id, String restrict, List<String>? tags)> adds = [];
  final List<int> deletes = [];
  Object? addError;
  BookmarkDetail detail = const BookmarkDetail(
    isBookmarked: false,
    restrict: BookmarkRestrict.public,
    tags: [],
  );

  /// When set, `fetchDetail` waits on it — a still-in-flight detail load.
  Completer<BookmarkDetail>? detailGate;
  Object? detailError;
  UserBookmarkTagPage tagPage = const UserBookmarkTagPage(
    tags: [],
    nextUrl: null,
  );

  @override
  Future<void> addIllust(
    int id,
    BookmarkRestrict restrict, {
    List<String>? tags,
    CancelToken? cancelToken,
  }) async {
    final error = addError;
    if (error != null) throw error;
    adds.add((id, restrict.name, tags));
  }

  @override
  Future<void> deleteIllust(int id, {CancelToken? cancelToken}) async {
    deletes.add(id);
  }

  @override
  Future<void> addNovel(
    int id,
    BookmarkRestrict restrict, {
    List<String>? tags,
    CancelToken? cancelToken,
  }) async {
    final error = addError;
    if (error != null) throw error;
    adds.add((id, restrict.name, tags));
  }

  @override
  Future<void> deleteNovel(int id, {CancelToken? cancelToken}) async {
    deletes.add(id);
  }

  @override
  Future<BookmarkDetail> fetchDetail(
    BookmarkKey key, {
    CancelToken? cancelToken,
  }) async {
    final gate = detailGate;
    if (gate != null) await gate.future;
    final error = detailError;
    if (error != null) throw error;
    return detail;
  }

  @override
  Future<UserBookmarkTagPage> fetchUserTags(
    int userId, {
    required BookmarkEntityType entityType,
    required BookmarkRestrict restrict,
    String? cursor,
    CancelToken? cancelToken,
  }) async => tagPage;

  @override
  bool validateUserTagsCursor(
    int userId, {
    required BookmarkEntityType entityType,
    required BookmarkRestrict restrict,
    required String cursor,
  }) => false;
}

Future<(ProviderContainer, _RecordingRepository)> _pump(
  WidgetTester tester, {
  Widget? child,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
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
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: appLocalizationsDelegates,
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
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('unknown state shows outline heart; tap sends public add (R3)', (
    tester,
  ) async {
    final (container, repository) = await _pump(tester);

    expect(find.byIcon(Icons.favorite_outline_sharp), findsOneWidget);
    expect(find.bySemanticsLabel('收藏插画: work 1'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('收藏插画: work 1')),
      isSemantics(
        label: '收藏插画: work 1',
        isButton: true,
        hasToggledState: true,
        isToggled: false,
        hasTapAction: true,
      ),
    );

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
    expect(
      tester.getSemantics(find.bySemanticsLabel('收藏插画: work 1')),
      isSemantics(
        label: '收藏插画: work 1',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
    );
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

  testWidgets(
    'bookmarked long press opens the edit sheet prefilled from detail',
    (tester) async {
      final (container, repository) = await _pump(tester);
      const key = BookmarkKey(BookmarkEntityType.illust, 1);
      repository.detail = const BookmarkDetail(
        isBookmarked: true,
        restrict: BookmarkRestrict.private,
        tags: [
          BookmarkTagFacet(name: 'procreate', isRegistered: true),
          BookmarkTagFacet(name: 'らくがき', isRegistered: false),
        ],
      );
      container
          .read(bookmarkStoreProvider.notifier)
          .observeRemote(key, bookmarked: true, snapshotRevision: 0);
      await tester.pump();

      await tester.longPress(find.byType(BookmarkSwitchButton));
      await tester.pumpAndSettle();

      expect(find.text('编辑收藏'), findsOneWidget);
      expect(find.text('procreate'), findsOneWidget);
      expect(find.text('らくがき'), findsOneWidget);

      // Prefilled restrict is private; confirming overwrites with the same
      // tag set.
      await tester.ensureVisible(find.text('确定'));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(repository.adds, hasLength(1));
      expect(repository.adds.single.$2, 'private');
      expect(repository.adds.single.$3, ['procreate', 'らくがき']);
    },
  );

  testWidgets('edit sheet cannot confirm before the detail prefills', (
    tester,
  ) async {
    final (container, repository) = await _pump(tester);
    const key = BookmarkKey(BookmarkEntityType.illust, 1);
    repository.detailGate = Completer<BookmarkDetail>();
    container
        .read(bookmarkStoreProvider.notifier)
        .observeRemote(key, bookmarked: true, snapshotRevision: 0);
    await tester.pump();

    await tester.longPress(find.byType(BookmarkSwitchButton));
    // pumpAndSettle would time out — the prefill spinner animates forever
    // while the detail gate is closed. Bounded pumps instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Detail still in flight: the spinner stands in for the tag editor
    // and confirm is disabled — confirming here would overwrite a private
    // bookmark with the default public+empty-tags values.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    FilledButton confirm() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确定'));
    expect(confirm().onPressed, isNull);
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(repository.adds, isEmpty);

    // Once the detail lands, the sheet prefills and confirm unlocks.
    repository.detailGate!.complete(repository.detail);
    await tester.pumpAndSettle();
    expect(confirm().onPressed, isNotNull);
  });

  testWidgets('tag input and suggestion chips reach the add call', (
    tester,
  ) async {
    final (_, repository) = await _pump(tester);
    repository.tagPage = const UserBookmarkTagPage(
      tags: [UserBookmarkTag(name: 'illustration', count: 5)],
      nextUrl: null,
    );

    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    expect(find.text('收藏插画'), findsOneWidget);
    expect(find.text('常用标签'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '新タグ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('新タグ'), findsOneWidget);

    await tester.tap(find.text('illustration'));
    await tester.pump();

    await tester.ensureVisible(find.text('确定'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(repository.adds, hasLength(1));
    expect(repository.adds.single.$3, ['新タグ', 'illustration']);
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

    // Global control set: segmented restrict, outlined cancel, filled
    // confirm — same as the follow sheet and the bookmark tags page.
    expect(find.byType(SegmentedButton<BookmarkRestrict>), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);

    // Choose 私密 on the segmented control, then confirm.
    await tester.tap(find.text('私密'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(repository.adds, hasLength(1));
    expect(repository.adds.single.$2, 'private');
  });

  testWidgets('edit sheet caps content width at ContentWidths.form on '
      'expanded surfaces', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(tester);
    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    final capped = find.byWidgetPredicate(
      (w) => w is ConstrainedBox && w.constraints.maxWidth == 520,
    );
    expect(capped, findsOneWidget);
    expect(tester.getSize(capped).width, 520);
    // Centered on the expanded surface.
    expect(tester.getCenter(capped).dx, 700);
  });

  testWidgets('edit sheet uses full width on compact surfaces', (tester) async {
    await _pump(tester);
    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (w) => w is ConstrainedBox && w.constraints.maxWidth == 520,
      ),
      findsNothing,
    );
  });

  testWidgets('dirty draft asks before closing via cancel button', (
    tester,
  ) async {
    final (_, repository) = await _pump(tester);
    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    // Clean draft: cancel closes directly.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('收藏插画'), findsNothing);

    // Dirty draft: cancel asks first.
    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私密'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    expect(find.text('收藏插画'), findsOneWidget);
    expect(repository.adds, isEmpty);

    // Stay: dialog cancel keeps the sheet and its draft.
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('收藏插画'), findsOneWidget);
    expect(
      tester
          .widget<SegmentedButton<BookmarkRestrict>>(
            find.byType(SegmentedButton<BookmarkRestrict>),
          )
          .selected,
      {BookmarkRestrict.private},
    );

    // Leave: discard confirms and pops the sheet.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('收藏插画'), findsNothing);
    expect(repository.adds, isEmpty);
  });

  testWidgets('dirty draft asks before closing via drag dismiss and '
      'system back', (tester) async {
    await _pump(tester);
    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私密'));
    await tester.pumpAndSettle();

    // Downward fling on the sheet chrome is claimed by the draft guard.
    await tester.fling(find.text('收藏插画'), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('收藏插画'), findsOneWidget);

    // System back (maybePop path) hits the same confirmation.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('收藏插画'), findsNothing);
  });

  testWidgets('pending tag input text counts as draft and asks before '
      'closing', (tester) async {
    await _pump(tester);
    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    // Type but never commit — restrict and tags are untouched, yet the
    // pending text would be folded into the submit, so it is draft.
    await tester.enterText(find.byType(TextField), '途中タグ');
    await tester.pump();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);

    // Staying keeps the sheet and its pending text.
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('收藏插画'), findsOneWidget);
    expect(find.text('途中タグ'), findsOneWidget);
  });

  testWidgets('clean drag dismiss and cancel close without a prompt', (
    tester,
  ) async {
    await _pump(tester);
    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    await tester.fling(find.text('收藏插画'), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(find.text('收藏插画'), findsNothing);
  });

  testWidgets('failed confirm keeps the sheet open and preserves the draft', (
    tester,
  ) async {
    final (_, repository) = await _pump(tester);
    repository.addError = StateError('boom');

    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私密'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新タグ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // Sheet stays open, the inline error is visible, and the draft is
    // untouched — nothing was submitted.
    expect(find.text('收藏插画'), findsOneWidget);
    expect(find.textContaining('收藏操作失败'), findsWidgets);
    expect(repository.adds, isEmpty);
    expect(
      tester
          .widget<SegmentedButton<BookmarkRestrict>>(
            find.byType(SegmentedButton<BookmarkRestrict>),
          )
          .selected,
      {BookmarkRestrict.private},
    );
    expect(find.text('新タグ'), findsOneWidget);

    // Retrying after the repository recovers submits the same draft.
    repository.addError = null;
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('收藏插画'), findsNothing);
    expect(repository.adds, hasLength(1));
    expect(repository.adds.single.$2, 'private');
    expect(repository.adds.single.$3, ['新タグ']);
  });

  testWidgets('residual tag input text merges into the submitted tags', (
    tester,
  ) async {
    final (_, repository) = await _pump(tester);
    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    // Type but never commit via the keyboard: confirm still folds the
    // pending text into the tag list.
    await tester.enterText(find.byType(TextField), '途中タグ');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('收藏插画'), findsNothing);
    expect(repository.adds, hasLength(1));
    expect(repository.adds.single.$3, ['途中タグ']);
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
