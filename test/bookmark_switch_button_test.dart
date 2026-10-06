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
import 'package:parfait/app/motion/motion_tokens.dart';
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

  testWidgets('haptics follow the settled outcome', (tester) async {
    final haptics = recordHaptics();
    final (_, repository) = await _pump(tester);

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();
    expect(haptics.roles, [HapticRole.success]);

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();
    expect(repository.deletes, [1]);
    expect(haptics.roles, [HapticRole.success, HapticRole.select]);

    // The throttle reads the wall clock; let the heavy lane re-arm too.
    await tester.runAsync(() => Future<void>.delayed(AppHaptics.heavyInterval));
    repository.addError = StateError('boom');
    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();
    expect(haptics.roles, [
      HapticRole.success,
      HapticRole.select,
      HapticRole.error,
    ]);
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

  testWidgets('edit sheet lifts above the keyboard and keeps confirm '
      'reachable', (tester) async {
    // Phone-tall surface so the shrunken band still fits the fixed header
    // and the action row above a mid-size IME.
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final (_, repository) = await _pump(tester);
    await tester.longPress(find.byType(BookmarkSwitchButton));
    await tester.pumpAndSettle();

    const keyboardTop = 800 - 300;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    // The modal route does not consume viewInsets: the sheet lifts above
    // the IME via its own bottom padding and shrinks into the remaining
    // height, so the confirm row ends above the keyboard and still taps.
    final confirmRect = tester.getRect(find.widgetWithText(FilledButton, '确定'));
    expect(confirmRect.bottom, lessThanOrEqualTo(keyboardTop));
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(repository.adds, hasLength(1));
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

  testWidgets('failure surfaces a snackbar and restores the icon (R5)', (
    tester,
  ) async {
    final (_, repository) = await _pump(tester);
    repository.addError = StateError('boom');

    await tester.tap(find.byType(BookmarkSwitchButton));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('收藏操作失败'), findsOneWidget);
    // C8/D1: raw exception text never reaches the SnackBar — it lands in
    // the crash log instead.
    expect(find.textContaining('boom'), findsNothing);
    expect(find.byIcon(Icons.favorite_outline_sharp), findsOneWidget);
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
    /// seen (1 while the heart is replaced by the pending spinner).
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

    testWidgets('a landed add pops the heart to ~1.2 and settles at 1', (
      tester,
    ) async {
      await _pump(tester);

      await tester.tap(find.byType(BookmarkSwitchButton));
      final peak = await peakScale(tester);

      expect(find.byIcon(Icons.favorite_sharp), findsOneWidget);
      expect(peak, inInclusiveRange(1.15, 1.25));
      await tester.pumpAndSettle();
      expect(heartScale(tester), 1);
    });

    testWidgets('a removal, a refresh or a failed add does not pop', (
      tester,
    ) async {
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

      repository.addError = StateError('boom');
      await tester.tap(find.byType(BookmarkSwitchButton));
      expect(await peakScale(tester), 1);
      await tester.pumpAndSettle();
    });

    testWidgets('reduced motion bookmarks without the pop', (tester) async {
      final (container, _) = await _pump(
        tester,
        child: const MotionScope(
          reduce: true,
          child: BookmarkSwitchButton(illustId: 1, title: 'work 1'),
        ),
      );

      await tester.tap(find.byType(BookmarkSwitchButton));
      expect(await peakScale(tester), 1);
      expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isTrue);
    });

    testWidgets('the sheet pops the heart for a new bookmark, not an edit', (
      tester,
    ) async {
      final (container, repository) = await _pump(tester);

      await tester.longPress(find.byType(BookmarkSwitchButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      expect(await peakScale(tester), inInclusiveRange(1.15, 1.25));
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
