import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/motion/state_icon_switcher.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/features/settings/pages/download_task_presentation.dart';
import 'package:parfait/features/settings/pages/download_tasks_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/app/widgets/prompt_host.dart';
import 'package:parfait/app/widgets/sliver_surface_list.dart';

import 'helpers/download_world.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        builder: promptHostBuilder,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: [
          Locale('zh'),
          Locale('en'),
          Locale('ja'),
          Locale('ru'),
        ],
        locale: Locale('zh'),
        home: DownloadTasksPage(),
      ),
    ),
  );
  await tester.pump();
}

/// A built row's `download-task-*`/`download-group-*` key, onstage or in the
/// lazy cache — this is how we prove the list builds on demand (R6).
Finder _taskRows({bool skipOffstage = true}) => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('download-task-'),
  skipOffstage: skipOffstage,
);

Finder _taskRow(String taskId) => find.byKey(ValueKey('download-task-$taskId'));

Finder _groupHeader(String groupId) =>
    find.byKey(ValueKey('download-group-$groupId'));

/// The surfaces of the groups with a row built, top to bottom, in the
/// coordinates [WidgetTester.getRect] uses.
List<RRect> _groupSurfaces(WidgetTester tester) {
  final sliver = tester.renderObject<RenderSliverSurfaceList>(
    find.byType(SliverSurfaceList),
  );
  final origin = MatrixUtils.transformPoint(
    sliver.getTransformTo(null),
    Offset.zero,
  );
  return [for (final surface in sliver.surfaces) surface.shift(origin)];
}

RRect _groupSurface(WidgetTester tester) => _groupSurfaces(tester).single;

/// The group's one surface runs from below the gap atop its [header] to
/// [last]'s bottom, across the rows' width, with the card's corners.
void _expectSurfaceSpans(WidgetTester tester, Finder header, Finder last) {
  final surface = _groupSurface(tester);
  final headerRect = tester.getRect(header);
  expect(
    surface.outerRect,
    rectMoreOrLessEquals(
      Rect.fromLTRB(
        headerRect.left,
        headerRect.top + FuncSpacing.sm,
        headerRect.right,
        tester.getRect(last).bottom,
      ),
    ),
  );
  expect(surface.tlRadius, FuncShape.card.topLeft);
  expect(surface.trRadius, FuncShape.card.topRight);
  expect(surface.blRadius, FuncShape.card.bottomLeft);
  expect(surface.brRadius, FuncShape.card.bottomRight);
}

/// The selection bar's title: the bare count, read out as [label].
Finder _selectionTitle(String label) => find.byWidgetPredicate(
  (widget) => widget is Text && widget.semanticsLabel == label,
);

/// Lets the Undo prompt finish sliding in, then taps Undo.
Future<void> _tapUndo(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(promptAction('撤销'));
}

void main() {
  testWidgets('group header pauses, resumes and cancels children', (
    tester,
  ) async {
    final gates = [Completer<void>(), Completer<void>()];
    final resumeGates = [Completer<void>(), Completer<void>()];
    final (container, manager, transport) = await makeDownloadWorld(
      responses: [
        gatedResponse(gates[0], byte: 1),
        gatedResponse(gates[1], byte: 2),
        gatedResponse(resumeGates[0], byte: 3),
        gatedResponse(resumeGates[1], byte: 4),
      ],
    );
    final group = manager.submitGroup([downloadRequest(1), downloadRequest(2)]);
    await _pumpPage(tester, container);
    await pumpUntil(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.running),
    );

    final header = _groupHeader(group.id);
    expect(
      find.descendant(of: header, matching: find.text('批量下载 · 2 项')),
      findsOneWidget,
    );
    // Collapsed by default (D1) — children stay out of the list entirely.
    expect(_taskRows(skipOffstage: false), findsNothing);
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.expand_more)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.pause)),
      findsOneWidget,
    );

    // Pause the whole group without expanding it; the running children
    // unwind once their gated chunk completes, queued ones flip directly.
    await tester.tap(
      find.descendant(of: header, matching: find.byIcon(Icons.pause)),
    );
    for (final gate in gates) {
      gate.complete();
    }
    await pumpUntil(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.retryable),
    );
    await tester.pump();
    expect(
      find.descendant(of: header, matching: find.textContaining('已暂停')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
    );

    // Resume re-submits every child; the group tracks the new job ids.
    await tester.tap(
      find.descendant(of: header, matching: find.byIcon(Icons.play_arrow)),
    );
    await pumpUntil(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.running),
    );
    expect(transport.openedUrls, hasLength(4));

    // Cancel lands every child in canceled — preserved output is dropped.
    await tester.tap(
      find.descendant(of: header, matching: find.byIcon(Icons.close)),
    );
    for (final gate in resumeGates) {
      gate.complete();
    }
    await pumpUntil(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.canceled),
    );
    await tester.pump();
    // A canceled group offers 重试 (refresh) — retry accepts canceled
    // work; 继续 (play_arrow) is reserved for the paused state.
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.refresh)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.play_arrow)),
      findsNothing,
    );
  });

  testWidgets('failed row offers retry and remove', (tester) async {
    final (container, manager, _) = await makeDownloadWorld(
      responses: [
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
          error: StateError('boom'),
        ),
      ],
    );
    final task = manager.submit(downloadRequest(1));
    await _pumpPage(tester, container);
    await pumpUntil(
      tester,
      () => manager.tasks.single.status == DownloadStatus.failed,
    );

    final row = _taskRow(task.id);
    expect(
      find.descendant(of: row, matching: find.textContaining('失败')),
      findsOneWidget,
    );
    // C8/D1: the status line carries the localized reason (StateError →
    // 未知错误), never the raw exception — that stays behind 详情.
    expect(
      find.descendant(of: row, matching: find.textContaining('未知错误')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('boom')),
      findsNothing,
    );
    await tester.tap(find.descendant(of: row, matching: find.text('详情')));
    await tester.pump();
    expect(
      find.descendant(of: row, matching: find.textContaining('boom')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byType(LinearProgressIndicator)),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.refresh)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
      findsOneWidget,
    );

    // Remove dismisses the failed record.
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(manager.tasks, isEmpty);
  });

  testWidgets('a task interrupted by a restart says so, not unknown error', (
    tester,
  ) async {
    // A running record carries no failure kind; recovery turns it into a
    // kindless retryable task that must not read as 未知错误.
    installMemoryPreferences();
    final request = downloadRequest(7);
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-7',
      jobId: 'job-7',
      groupId: null,
      request: request,
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 9, 30),
    );
    final store = MemoryDownloadRecoveryStore();
    await store.upsert(
      DownloadRecoveryRecord(
        jobId: 'job-7',
        dedupeKey: request.dedupeKey,
        snapshot: snapshot,
        owner: const DownloadOutputOwner(
          ownerId: 'output-7',
          jobId: 'job-7',
          accountId: 'account-a',
        ),
        status: DownloadStatus.running,
      ),
    );
    final manager = DownloadManager(
      transport: FakeTransport(),
      sinkFactory: MemorySinkFactory(),
      submissionContext: () =>
          const DownloadSubmissionContext(accountId: 'account-a'),
      recoveryStore: store,
    );
    final report = await manager.recover();
    expect(report.retryableJobIds, ['job-7']);
    expect(manager.taskById('job-7')!.failureKind, isNull);
    final container = ProviderContainer(
      overrides: [downloadManagerProvider.overrideWithValue(manager)],
    );
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    final row = _taskRow('job-7');
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('应用重启时下载中断，点重试继续'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('未知错误')),
      findsNothing,
    );
    expect(find.descendant(of: row, matching: find.text('详情')), findsOneWidget);
  });

  testWidgets('a group of one is a plain task row', (tester) async {
    final (container, manager, _) = await makeDownloadWorld(
      maxConcurrent: 1,
      responses: [gatedResponse(Completer<void>())],
    );
    final group = manager.submitGroup([downloadRequest(1)]);
    await _pumpPage(tester, container);
    await pumpUntil(tester, () => manager.tasks.isNotEmpty);
    await tester.pump();

    expect(_groupHeader(group.id), findsNothing);
    expect(_taskRows(), findsOneWidget);
  });

  testWidgets('a collapsed group expands on tap and folds its children in', (
    tester,
  ) async {
    final (container, manager, _) = await makeDownloadWorld(
      maxConcurrent: 1,
      responses: [gatedResponse(Completer<void>())],
    );
    final group = manager.submitGroup([downloadRequest(1), downloadRequest(2)]);
    await _pumpPage(tester, container);
    await pumpUntil(tester, () => manager.tasks.isNotEmpty);
    await tester.pump();

    final header = _groupHeader(group.id);
    expect(header, findsOneWidget);
    expect(_taskRows(skipOffstage: false), findsNothing);
    // A collapsed group is a card of its own.
    _expectSurfaceSpans(tester, header, header);
    final headerInk = find
        .descendant(of: header, matching: find.byType(InkWell))
        .first;
    final collapsedRect = tester.getRect(headerInk);
    // The header never changes parent, so it keeps its element and the
    // ripple of the tap that opens the group.
    final headerElement = tester.element(headerInk);
    final headerMaterial = Material.of(tester.element(headerInk));

    // Tap the header title to expand: children appear on the group's one
    // surface, inside the header's horizontal bounds.
    await tester.tap(find.text('批量下载 · 2 项'));
    await tester.pump();
    expect((headerMaterial as dynamic).debugInkFeatures, isNotEmpty);
    // The children grow in from zero height (a zero-height row at the top
    // of its sliver counts as offstage), then sit at full size.
    final firstChild = find.byKey(
      ValueKey('download-task-${manager.tasks.first.id}'),
      skipOffstage: false,
    );
    final lastChild = _taskRow(manager.tasks.last.id);
    expect(tester.getSize(firstChild).height, 0);
    expect(tester.getRect(headerInk), collapsedRect);
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSize(firstChild).height, greaterThan(0));
    // The outline grows with the rows: its bottom corners never wait.
    _expectSurfaceSpans(tester, header, lastChild);
    expect((headerMaterial as dynamic).debugInkFeatures, isNotEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    final fullHeight = tester.getSize(firstChild).height;
    expect(_taskRows(), findsNWidgets(2));
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.expand_less)),
      findsOneWidget,
    );
    _expectSurfaceSpans(tester, header, lastChild);
    expect(tester.element(headerInk), same(headerElement));
    final headerRect = tester.getRect(header);
    final surface = find.byType(SliverSurfaceList);
    expect(
      tester.widget<SliverSurfaceList>(surface).color,
      Theme.of(tester.element(header)).colorScheme.surfaceContainer,
    );
    expect(find.ancestor(of: header, matching: surface), findsOneWidget);
    for (final task in manager.tasks) {
      final child = _taskRow(task.id);
      final childRect = tester.getRect(child);
      expect(childRect.left, greaterThanOrEqualTo(headerRect.left));
      expect(childRect.right, lessThanOrEqualTo(headerRect.right));
      expect(find.ancestor(of: child, matching: surface), findsOneWidget);
    }

    // Tap again to collapse: the children fold away on the surface, then
    // leave the list and the header is a card of its own again.
    await tester.tap(find.text('批量下载 · 2 项'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSize(firstChild).height, inExclusiveRange(0, fullHeight));
    _expectSurfaceSpans(tester, header, lastChild);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_taskRows(skipOffstage: false), findsNothing);
    _expectSurfaceSpans(tester, header, header);
    expect(tester.getRect(headerInk), collapsedRect);
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.expand_more)),
      findsOneWidget,
    );
    expect(tester.element(headerInk), same(headerElement));
  });

  testWidgets('a five-hundred-item list only builds the visible rows', (
    tester,
  ) async {
    final (container, manager, _) = await makeDownloadWorld(
      maxConcurrent: 1,
      responses: [gatedResponse(Completer<void>())],
    );
    for (var i = 0; i < 500; i++) {
      manager.submit(downloadRequest(i + 1));
    }
    await _pumpPage(tester, container);
    await pumpUntil(tester, () => manager.tasks.isNotEmpty);
    await tester.pump();

    // The lazy lists only realize the viewport plus its cache extent —
    // far below the full 500. >0 guards against a degenerate "no keyed
    // rows at all" pass (an eager list had none).
    expect(
      _taskRows(skipOffstage: false).evaluate().length,
      inInclusiveRange(1, 20),
    );
  });

  testWidgets(
    'selection mode batch-removes terminal and batch-cancels active',
    (tester) async {
      final haptics = recordHaptics();

      final gate = Completer<void>();
      final (container, manager, _) = await makeDownloadWorld(
        responses: [
          ScriptedResponse(
            contentLength: 1,
            chunks: [
              [1],
            ],
          ),
          ScriptedResponse(
            contentLength: 1,
            chunks: [
              [2],
            ],
            completers: [gate],
          ),
        ],
      );
      manager.submit(downloadRequest(1));
      manager.submit(downloadRequest(2));
      await _pumpPage(tester, container);
      await pumpUntil(
        tester,
        () =>
            manager.tasks.any((t) => t.status == DownloadStatus.succeeded) &&
            manager.tasks.any((t) => t.status == DownloadStatus.running),
      );

      // The manage entry spells itself out as a text button (R5) — the
      // bare checklist icon is gone.
      expect(find.widgetWithText(TextButton, '管理'), findsOneWidget);
      expect(find.byIcon(Icons.checklist_outlined), findsNothing);

      // Entering selection mode fires the explicit vibration; the AppBar
      // swaps to the count surface.
      await tester.tap(find.widgetWithText(TextButton, '管理'));
      await tester.pump();
      expect(_selectionTitle('已选 0 项'), findsOneWidget);
      expect(haptics.roles, [HapticRole.confirm]);

      // Select-all is the light tick; selected rows drop their nested
      // action row for the check affordance.
      await tester.tap(find.byIcon(Icons.select_all));
      await tester.pump();
      expect(_selectionTitle('已选 2 项'), findsOneWidget);
      expect(haptics.roles.last, HapticRole.select);
      // The check marks swap in; let the swap finish.
      await tester.pump(const Duration(milliseconds: 300));
      for (final task in manager.tasks) {
        final mark = find.byKey(ValueKey('download-select-${task.id}'));
        expect(tester.widget<Icon>(mark).icon, Icons.check_circle);
        expect(
          find.ancestor(of: mark, matching: find.byType(StateIconSwitcher)),
          findsOneWidget,
        );
      }
      expect(find.byIcon(Icons.open_in_new), findsNothing);

      // Batch remove qualifies only the terminal task and asks for no
      // confirmation — Undo brings the record back instead (D5).
      final finished = manager.tasks.firstWhere(
        (t) => t.status == DownloadStatus.succeeded,
      );
      await tester.tap(find.byIcon(Icons.remove_circle_outline));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(manager.tasks.single.status, DownloadStatus.running);
      expect(_selectionTitle('已选 0 项'), findsNothing);
      expect(find.text('下载任务'), findsOneWidget);
      expect(find.text('已移除 1 条记录'), findsOneWidget);
      await _tapUndo(tester);
      await tester.pump();
      expect(manager.taskById(finished.id), isNotNull);
      expect(manager.tasks.first.id, finished.id);
      await tester.pump();
      expect(_taskRow(finished.id), findsOneWidget);
      PromptHost.of(
        tester.element(find.byType(DownloadTasksPage)),
      ).hideCurrent();
      await tester.pump(const Duration(milliseconds: 300));

      // Batch cancel on the running task still goes through the confirm
      // dialog — canceling deletes partial output, which Undo cannot bring
      // back — then the task unwinds once its gate opens.
      final running = manager.tasks.firstWhere(
        (t) => t.status == DownloadStatus.running,
      );
      await tester.tap(find.widgetWithText(TextButton, '管理'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.select_all));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.cancel_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '取消'));
      gate.complete();
      await pumpUntil(
        tester,
        () => manager.taskById(running.id)!.status == DownloadStatus.canceled,
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(manager.taskById(finished.id)!.status, DownloadStatus.succeeded);
    },
  );

  group('row tap, clear completed and undo', () {
    /// The page under a stand-in router: a work opens as a text page.
    Future<GoRouter> pumpRouted(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      final router = GoRouter(
        initialLocation: '/downloads',
        routes: [
          GoRoute(
            path: '/downloads',
            builder: (_, _) => const DownloadTasksPage(),
            routes: [
              GoRoute(
                path: 'illust/:id',
                builder: (_, state) =>
                    Text('opened ${state.pathParameters['id']}'),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: const [Locale('zh')],
            locale: const Locale('zh'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      return router;
    }

    List<ScriptedResponse> done(int count) => [
      for (var i = 0; i < count; i++)
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [i],
          ],
        ),
    ];

    testWidgets('a task row opens its work; management taps select', (
      tester,
    ) async {
      final (container, manager, _) = await makeDownloadWorld(
        responses: done(1),
      );
      final task = manager.submit(downloadRequest(7));
      await mockNetworkImagesFor(() async {
        final router = await pumpRouted(tester, container);
        await pumpUntil(
          tester,
          () => manager.tasks.single.status == DownloadStatus.succeeded,
        );
        await tester.pump();

        final semantics = tester.ensureSemantics();
        expect(
          tester.getSemantics(
            find
                .descendant(
                  of: _taskRow(task.id),
                  matching: find.byType(Semantics),
                )
                .first,
          ),
          isSemantics(isButton: true, onTapHint: '打开作品'),
        );
        semantics.dispose();

        await tester.tap(
          find.text(downloadTaskTitle(manager.taskById(task.id)!)),
        );
        await tester.pumpAndSettle();
        expect(find.text('opened 7'), findsOneWidget);
        router.pop();
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(TextButton, '管理'));
        await tester.pump();
        await tester.tap(
          find.text(downloadTaskTitle(manager.taskById(task.id)!)),
        );
        await tester.pump();
        expect(_selectionTitle('已选 1 项'), findsOneWidget);
        expect(find.text('opened 7'), findsNothing);
      });
    });

    testWidgets('clear completed leaves failures and is undone in place', (
      tester,
    ) async {
      final (container, manager, _) = await makeDownloadWorld(
        maxConcurrent: 1,
        responses: [
          ...done(1),
          ScriptedResponse(contentLength: 1, error: StateError('boom')),
          ...done(1),
        ],
      );
      for (var id = 1; id <= 3; id++) {
        manager.submit(downloadRequest(id));
      }
      final clear = find.byTooltip('清除已完成');
      await mockNetworkImagesFor(() async {
        await _pumpPage(tester, container);
        expect(clear, findsNothing);
        await pumpUntil(
          tester,
          () => manager.tasks.every((t) => isTerminal(t.status)),
        );
        await tester.pump();
        final order = [for (final task in manager.tasks) task.id];

        await tester.tap(clear);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(manager.tasks.single.status, DownloadStatus.failed);
        expect(find.text('已移除 2 条记录'), findsOneWidget);
        // Only failures left: nothing to clear.
        expect(clear, findsNothing);

        await _tapUndo(tester);
        await tester.pump();
        expect([for (final task in manager.tasks) task.id], order);
      });
    });

    testWidgets('removing a finished group is undone with its header', (
      tester,
    ) async {
      final (container, manager, _) = await makeDownloadWorld(
        responses: done(2),
      );
      final group = manager.submitGroup([
        downloadRequest(1),
        downloadRequest(2),
      ]);
      await mockNetworkImagesFor(() async {
        await _pumpPage(tester, container);
        await pumpUntil(
          tester,
          () =>
              manager.tasks.every((t) => t.status == DownloadStatus.succeeded),
        );
        await tester.pump();

        await tester.tap(
          find.descendant(
            of: _groupHeader(group.id),
            matching: find.byIcon(Icons.remove_circle_outline),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(manager.groups, isEmpty);
        expect(find.text('已移除 2 条记录'), findsOneWidget);

        await _tapUndo(tester);
        await tester.pump();
        await tester.pump();
        expect(manager.groups.single.id, group.id);
        expect(manager.groups.single.jobIds, group.jobIds);
        expect(_groupHeader(group.id), findsOneWidget);
      });
    });
  });
}
