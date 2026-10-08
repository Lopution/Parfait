import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/recording_haptics.dart';
import 'helpers/bookmark_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'package:parfait/app/haptics/app_haptics.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/bookmark/bookmark_repository.dart';
import 'package:parfait/core/bookmark/bookmark_store.dart';
import 'package:parfait/app/widgets/bookmark_switch_button.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'helpers/prompt_host.dart';

Future<(ProviderContainer, RecordingBookmarkRepository)> _pump(
  WidgetTester tester, {
  Widget? child,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final repository = RecordingBookmarkRepository();
  final container = ProviderContainer(
    overrides: [
      accountStoreProvider.overrideWith(StubAccountStore.new),
      bookmarkRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: promptHostBuilder,
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

/// The edit sheet's "private" switch row.
SwitchListTile _privateSwitch(WidgetTester tester) =>
    tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '私密'));

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('unknown state shows outline heart; tap sends public add (R3)', (
    tester,
  ) async {
    final (container, repository) = await _pump(tester);

    expect(find.byIcon(Icons.favorite_outline_sharp), findsOneWidget);
    expect(find.bySemanticsLabel('收藏插画：work 1'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('收藏插画：work 1')),
      isSemantics(
        label: '收藏插画：work 1',
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
      tester.getSemantics(find.bySemanticsLabel('收藏插画：work 1')),
      isSemantics(
        label: '收藏插画：work 1',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('haptics play on the tap; a failure adds an error', (
    tester,
  ) async {
    final haptics = recordHaptics();
    final (_, repository) = await _pump(tester);

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();
    expect(haptics.roles, [HapticRole.success]);

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();
    expect(repository.deletes, [1]);
    expect(haptics.roles, [HapticRole.success, HapticRole.select]);

    // The throttle reads the wall clock; let the heavy lane re-arm between
    // the tap's haptic and the failure's.
    await tester.runAsync(() => Future<void>.delayed(AppHaptics.heavyInterval));
    final gate = repository.addGate = Completer<void>();
    repository.addError = StateError('boom');
    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pump();
    expect(haptics.roles.last, HapticRole.success, reason: 'felt on the tap');
    await tester.runAsync(() => Future<void>.delayed(AppHaptics.heavyInterval));
    gate.complete();
    await tester.pumpAndSettle();
    expect(haptics.roles, [
      HapticRole.success,
      HapticRole.select,
      HapticRole.success,
      HapticRole.error,
    ]);
  });

  testWidgets('an unconfirmed add already shows the filled heart', (
    tester,
  ) async {
    final (container, repository) = await _pump(tester);
    final gate = repository.addGate = Completer<void>();

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pump();

    expect(find.byIcon(Icons.favorite_sharp), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(
      tester.getSemantics(find.bySemanticsLabel('收藏插画：work 1')),
      isSemantics(
        label: '收藏插画：work 1',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
        hasLongPressAction: false,
      ),
      reason: 'the sheet waits until the request settles',
    );
    const key = BookmarkKey(BookmarkEntityType.illust, 1);
    expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isFalse);

    gate.complete();
    await tester.pumpAndSettle();
    expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isTrue);
  });

  testWidgets('a failed add rolls the heart back and says why', (tester) async {
    final (_, repository) = await _pump(tester);
    final gate = repository.addGate = Completer<void>();
    repository.addError = StateError('boom');

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pump();
    expect(find.byIcon(Icons.favorite_sharp), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.favorite_outline_sharp), findsOneWidget);
    expect(find.textContaining('收藏操作失败'), findsOneWidget);
    await tester.pumpAndSettle();
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

  testWidgets('edit sheet locks the whole form while the detail prefills', (
    tester,
  ) async {
    final (container, repository) = await _pump(tester);
    const key = BookmarkKey(BookmarkEntityType.illust, 1);
    repository.detailGate = Completer<BookmarkDetail>();
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Detail still in flight: every editable control is inert — the tag
    // editor is replaced by the spinner and the restrict selector is
    // disabled. A mid-load restrict change used to flip the draft dirty,
    // which made the arriving prefill keep the empty tag list.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(_privateSwitch(tester).onChanged, isNull);
    await tester.tap(find.text('私密'));
    await tester.pump();
    expect(_privateSwitch(tester).value, isFalse);

    // The arriving detail fully populates the persisted state and editing
    // resumes.
    repository.detailGate!.complete(repository.detail);
    await tester.pumpAndSettle();
    expect(_privateSwitch(tester).onChanged, isNotNull);
    expect(_privateSwitch(tester).value, isTrue);
    expect(find.text('procreate'), findsOneWidget);
    expect(find.text('らくがき'), findsOneWidget);

    // Submission stays possible afterwards with the prefilled values.
    await tester.ensureVisible(find.text('确定'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(repository.adds, hasLength(1));
    expect(repository.adds.single.$2, 'private');
    expect(repository.adds.single.$3, ['procreate', 'らくがき']);
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
    final haptics = recordHaptics();
    final (_, repository) = await _pump(tester);

    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    expect(find.text('收藏插画'), findsOneWidget);
    expect(find.text('work 1'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);

    // A "private" switch, outlined cancel, filled confirm.
    expect(_privateSwitch(tester).value, isFalse);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);

    // Switch 私密 on, then confirm.
    await tester.tap(find.text('私密'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(repository.adds, hasLength(1));
    expect(repository.adds.single.$2, 'private');
    // Sheet opened, switch flipped on, submit landed.
    expect(haptics.roles, [
      HapticRole.longPress,
      HapticRole.toggleOn,
      HapticRole.success,
    ]);
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
    expect(_privateSwitch(tester).value, isTrue);

    // Leave: discard confirms and pops the sheet.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('收藏插画'), findsNothing);
    expect(repository.adds, isEmpty);
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
    expect(_privateSwitch(tester).value, isTrue);
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

  group('heart pop', () {
    const key = BookmarkKey(BookmarkEntityType.illust, 1);

    double heartScale(WidgetTester tester) => tester
        .widget<ScaleTransition>(
          find.descendant(
            of: find.byType(BookmarkSwitchButton),
            matching: find.byType(ScaleTransition),
          ),
        )
        .scale
        .value;

    /// Pumps [span] in small steps and returns the largest heart scale
    /// seen.
    Future<double> peakScale(
      WidgetTester tester, {
      Duration span = const Duration(milliseconds: 600),
    }) async {
      const step = Duration(milliseconds: 4);
      var peak = 1.0;
      for (var t = Duration.zero; t < span; t += step) {
        await tester.pump(step);
        final heart = find.descendant(
          of: find.byType(BookmarkSwitchButton),
          matching: find.byType(ScaleTransition),
        );
        if (heart.evaluate().isNotEmpty && heartScale(tester) > peak) {
          peak = heartScale(tester);
        }
      }
      return peak;
    }

    testWidgets('a removal or a refresh does not pop', (tester) async {
      final (container, repository) = await _pump(tester);

      // Refresh: the store learns the work is bookmarked.
      container
          .read(bookmarkStoreProvider.notifier)
          .observeRemote(key, bookmarked: true, snapshotRevision: 0);
      expect(await peakScale(tester), 1);
      expect(find.byIcon(Icons.favorite_sharp), findsOneWidget);

      await tester.tap(find.byType(BookmarkSwitchButton));
      expect(await peakScale(tester), 1);
      expect(repository.deletes, [1]);
    });

    testWidgets('the sheet pops the heart for a new bookmark, not an edit', (
      tester,
    ) async {
      final (container, repository) = await _pump(tester);

      await tester.longPress(find.byType(BookmarkSwitchButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      expect(await peakScale(tester), inInclusiveRange(1.2, 1.3));
      await tester.pumpAndSettle();
      expect(repository.adds, hasLength(1));

      // Editing an existing bookmark lands no new one.
      expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isTrue);
      await tester.longPress(find.byType(BookmarkSwitchButton));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确定'));
      await tester.tap(find.text('确定'));
      expect(await peakScale(tester), 1);
      await tester.pumpAndSettle();
      expect(repository.adds, hasLength(2));
    });
  });
}
