import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/motion/press_scale.dart';
import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/person_avatar.dart';
import 'package:parfait/app/pull_to_refresh.dart';
import 'package:parfait/app/widgets/bookmark_switch_button.dart';
import 'package:parfait/app/widgets/feed/feed_selection.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/tab_swipe_switcher.dart';
import 'package:parfait/core/actionqueue/action_bootstrap.dart';
import 'package:parfait/core/actionqueue/action_models.dart';
import 'package:parfait/core/actionqueue/action_store.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/api_responses.dart';
import 'helpers/bookmark_world.dart';
import 'helpers/card_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';
import 'helpers/view_size.dart';

Future<void> _sendKeyChord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  LogicalKeyboardKey? modifier,
}) async {
  if (modifier != null) await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (modifier != null) await tester.sendKeyUpEvent(modifier);
}

void main() {
  testWidgets(
    'SelectableFeedHost gates >=600dp multi-select, Ctrl/Cmd+Click, Shift range, Ctrl+A, Esc, and batch bookmark/download',
    (tester) async {
      final bookmarks = BookmarkApi();
      final actionStore = InMemoryActionStore();
      final container = await signedInApiContainer(
        PixivApi({...backgroundRoutes, ...bookmarks.routes}).client,
        overrides: [
          actionStoreProvider.overrideWithValue(actionStore),
          imageWorkerProvider.overrideWithValue(stalledImageWorker()),
        ],
      );
      final items = [
        parseIllust(illustJson(1)),
        parseIllust(illustJson(2)),
        parseIllust(illustJson(3)),
      ];
      final navigated = <int>[];
      final widthNotifier = ValueNotifier<double>(500);
      addTearDown(widthNotifier.dispose);

      Widget detailStub(GoRouterState state) {
        final id = int.parse(state.pathParameters['id']!);
        navigated.add(id);
        return Text('detail-$id');
      }

      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/illust/:id',
            builder: (_, state) => detailStub(state),
          ),
          GoRoute(
            path: '/recommended',
            builder: (context, _) => Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: ValueListenableBuilder<double>(
                  valueListenable: widthNotifier,
                  builder: (context, width, _) => SizedBox(
                    width: width,
                    height: 600,
                    child: SelectableFeedHost(
                      child: Builder(
                        builder: (context) {
                          final sel = FeedSelectionScope.maybeOf(context)!;
                          sel.syncItems(items);
                          return CustomScrollView(
                            slivers: [
                              SliverGrid.count(
                                crossAxisCount: 3,
                                childAspectRatio: 0.72,
                                children: [
                                  for (final entity in items)
                                    FeedSelectableCardDecorator(
                                      entityId: entity.id,
                                      child: IllustCard(entity: entity),
                                    ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            routes: [
              GoRoute(
                path: 'illust/:id',
                builder: (_, state) => detailStub(state),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

      for (final (platform, modifier) in [
        (TargetPlatform.windows, LogicalKeyboardKey.controlLeft),
        (TargetPlatform.macOS, LogicalKeyboardKey.metaLeft),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          navigated.clear();
          bookmarks.adds.clear();
          widthNotifier.value = 500;
          setViewSize(tester, const Size(1280, 800));
          await tester.pumpWidget(
            localizedRouterApp(
              router,
              container: container,
              builder: (ctx, child) => promptHostBuilder(
                ctx,
                KeyboardBack(router: router, child: child!),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Narrow (<600dp): Ctrl/Cmd+A and Ctrl/Cmd+Click do not select; card navigates.
          await _sendKeyChord(
            tester,
            LogicalKeyboardKey.keyA,
            modifier: modifier,
          );
          await tester.pump();
          expect(find.byKey(const Key('feed-batch-action-bar')), findsNothing);
          await tester.sendKeyDownEvent(modifier);
          await tester.tap(find.byType(IllustCard).at(0));
          await tester.sendKeyUpEvent(modifier);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('feed-batch-action-bar')), findsNothing);
          expect(navigated, [1]);
          router.pop();
          await tester.pumpAndSettle();

          // Wide (>=600dp): Ctrl/Cmd+Click enters selection mode.
          widthNotifier.value = 800;
          await tester.pumpAndSettle();
          await tester.sendKeyDownEvent(modifier);
          await tester.tap(find.byType(IllustCard).at(0));
          await tester.sendKeyUpEvent(modifier);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('feed-batch-action-bar')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('feed-select-badge-1')), findsOneWidget);

          // Shift+Click selects inclusive range [0..2].
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.tap(find.byType(IllustCard).at(2));
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pump();
          expect(find.textContaining('3'), findsWidgets);

          // Escape clears active selection without popping route.
          await _sendKeyChord(tester, LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('feed-batch-action-bar')), findsNothing);

          // Ctrl/Cmd+A selects all loaded cards.
          await _sendKeyChord(
            tester,
            LogicalKeyboardKey.keyA,
            modifier: modifier,
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('feed-batch-action-bar')),
            findsOneWidget,
          );

          if (platform == TargetPlatform.windows) {
            // Enqueue batch public bookmarks -> durable ActionQueue entries.
            bookmarks.addGate = Completer<void>();
            await tester.tap(
              find.text(lookupAppLocalizations(zhCN).batchBookmarkPublic),
            );
            await tester.pumpAndSettle();
            final queuedRows = await actionStore.listFor(testerAccount.id);
            expect(
              queuedRows.where((r) => r.type == ActionTypes.bookmarkAdd),
              hasLength(3),
            );
            bookmarks.addGate!.complete();
            await tester.pumpAndSettle();
            expect(bookmarks.adds.map((e) => e.$1).toSet(), {1, 2, 3});
            expect(
              find.byKey(const Key('feed-batch-action-bar')),
              findsNothing,
            );
          } else {
            // Clear selection on macOS iteration before next loop.
            await _sendKeyChord(tester, LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    },
  );

  testWidgets(
    'Pointer IllustCard keeps immediate PressScale, omits touch long-press, and uses subtle hover highlight without duplicate pills',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final (container, _, _) = await makeCardWorld();
        final entity = parseIllust(illustJson(88));
        await tester.pumpWidget(
          localizedApp(
            container: container,
            builder: (ctx, child) =>
                promptHostBuilder(ctx, InputModalityScope(child: child!)),
            body: Center(
              child: SizedBox(width: 220, child: IllustCard(entity: entity)),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(PressScale),
          ),
          findsOneWidget,
        );
        final detector = tester.widget<GestureDetector>(
          find
              .descendant(
                of: find.byType(IllustCard),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        expect(detector.onLongPress, isNull);

        // Hover highlights the card border/overlay without duplicating footer controls.
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(PersonAvatar),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.text(entity.user.name),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(BookmarkSwitchButton),
          ),
          findsOneWidget,
        );
        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(
          pointer.hover(tester.getCenter(find.byType(IllustCard))),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(PersonAvatar),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.text(entity.user.name),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(BookmarkSwitchButton),
          ),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'wide split TabSlideStack keeps resting neighbors offstage for both refresh and select-all',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      final tabs = TabController(length: 2, vsync: const TestVSync());
      final scrolls = [ScrollController(), ScrollController()];
      addTearDown(() {
        tabs.dispose();
        for (final s in scrolls) {
          s.dispose();
        }
      });
      final entities = [
        parseIllust(illustJson(10)),
        parseIllust(illustJson(20)),
      ];
      final selections = <FeedSelectionController?>[null, null];
      final refreshed = <int>[];

      await tester.pumpWidget(
        localizedApp(
          body: Row(
            children: [
              const SizedBox(width: 240),
              Expanded(
                child: TabSlideStack(
                  controller: tabs,
                  children: [
                    for (var i = 0; i < 2; i++)
                      SelectableFeedHost(
                        child: PullToRefresh(
                          scrollController: scrolls[i],
                          onRefresh: () async => refreshed.add(i),
                          child: Builder(
                            builder: (context) {
                              selections[i] = FeedSelectionScope.maybeOf(
                                context,
                              )!..syncItems([entities[i]]);
                              return ListView(
                                controller: scrolls[i],
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [Text('pane-$i')],
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 300),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final active in [0, 1]) {
        tabs.index = active;
        await tester.pumpAndSettle();
        expect(find.text('pane-$active'), findsOneWidget);
        expect(find.text('pane-${1 - active}'), findsNothing);
        expect(FeedSelectionAnchor.selectAllActive(), isTrue);
        await tester.pump();
        expect(selections[active]!.isSelected(entities[active].id), isTrue);
        expect(selections[1 - active]!.selectedCount, 0);
        selections[active]!.clearSelection();
        expect(PullToRefresh.triggerActive(), isTrue);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(refreshed, [0, 1]);
    },
  );
}
