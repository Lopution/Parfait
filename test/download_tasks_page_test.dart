import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/motion/state_icon_switcher.dart';
import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_request.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/core/platform/desktop_file_actions.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/settings/pages/download_tasks_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/app/widgets/app_dialog.dart';
import 'package:parfait/app/widgets/app_progress_bar.dart';
import 'package:parfait/app/widgets/prompt_host.dart';

import 'helpers/download_world.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/prompt_host.dart';
import 'helpers/waits.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/icons/ui_icons.dart';

/// Cancels end when [cancels] completes, as dropping kept bytes on disk
/// does.
class _SlowCancelManager extends DownloadManager {
  _SlowCancelManager(FakeTransport transport)
    : super(transport: transport, sinkFactory: MemorySinkFactory());

  final cancels = Completer<void>();
  var waiting = 0;

  @override
  Future<void> cancel(String taskId) async {
    await super.cancel(taskId);
    waiting++;
    await cancels.future;
  }
}

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
      find.descendant(of: header, matching: find.byIcon(UiIcons.expandMore)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byIcon(UiIcons.pause)),
      findsOneWidget,
    );

    // Pause the whole group without expanding it; the running children
    // unwind once their gated chunk completes, queued ones flip directly.
    await tester.tap(
      find.descendant(of: header, matching: find.byIcon(UiIcons.pause)),
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
      find.descendant(of: header, matching: find.byIcon(UiIcons.play)),
      findsOneWidget,
    );

    // Resume re-submits every child; the group tracks the new job ids.
    await tester.tap(
      find.descendant(of: header, matching: find.byIcon(UiIcons.play)),
    );
    await pumpUntil(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.running),
    );
    expect(transport.openedUrls, hasLength(4));

    // Cancel lands every child in canceled — preserved output is dropped.
    await tester.tap(
      find.descendant(of: header, matching: find.byIcon(UiIcons.close)),
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
      find.descendant(of: header, matching: find.byIcon(UiIcons.refresh)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byIcon(UiIcons.play)),
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
    // 未知错误), never the raw exception — that goes to the crash log.
    expect(
      find.descendant(of: row, matching: find.textContaining('未知错误')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('boom')),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.byType(AppProgressBar)),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(UiIcons.refresh)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(UiIcons.removeCircle)),
      findsOneWidget,
    );

    // Remove dismisses the failed record.
    await tester.tap(
      find.descendant(of: row, matching: find.byIcon(UiIcons.removeCircle)),
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
    final container = ProviderContainer.test(
      overrides: [downloadManagerProvider.overrideWithValue(manager)],
    );

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
    expect(find.descendant(of: row, matching: find.text('详情')), findsNothing);
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
      expect(find.byIcon(UiIcons.checklist), findsNothing);

      // Entering selection mode fires the explicit vibration; the AppBar
      // swaps to the count surface.
      await tester.tap(find.widgetWithText(TextButton, '管理'));
      await tester.pump();
      expect(_selectionTitle('已选 0 项'), findsOneWidget);
      expect(haptics.roles, [HapticRole.confirm]);

      // Select-all is the light tick; selected rows drop their nested
      // action row for the check affordance.
      await tester.tap(find.byIcon(UiIcons.selectAll));
      await tester.pump();
      expect(_selectionTitle('已选 2 项'), findsOneWidget);
      expect(haptics.roles.last, HapticRole.select);
      // The check marks swap in; let the swap finish.
      await tester.pump(const Duration(milliseconds: 300));
      for (final task in manager.tasks) {
        final mark = find.byKey(ValueKey('download-select-${task.id}'));
        expect(tester.widget<Icon>(mark).icon, UiIcons.checkCircle);
        expect(
          find.ancestor(of: mark, matching: find.byType(StateIconSwitcher)),
          findsOneWidget,
        );
      }
      expect(find.byIcon(AppIcons.externalLink), findsNothing);

      // Batch remove qualifies only the terminal task and asks for no
      // confirmation — Undo brings the record back instead (D5).
      final finished = manager.tasks.firstWhere(
        (t) => t.status == DownloadStatus.succeeded,
      );
      await tester.tap(find.byIcon(UiIcons.removeCircle));
      await tester.pump();
      expect(find.byType(AppAlertDialog), findsNothing);
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
      await tester.tap(find.byIcon(UiIcons.selectAll));
      await tester.pump();
      await tester.tap(find.byIcon(UiIcons.cancelCircle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AppAlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '取消'));
      gate.complete();
      await pumpUntil(
        tester,
        () => manager.taskById(running.id)!.status == DownloadStatus.canceled,
      );
      await tester.pump();
      expect(find.byType(AppProgressBar), findsNothing);
      expect(manager.taskById(finished.id)!.status, DownloadStatus.succeeded);
    },
  );

  testWidgets('a batch cancel ending after the page left is quiet', (
    tester,
  ) async {
    final manager = _SlowCancelManager(
      FakeTransport()..responses.add(gatedResponse(Completer<void>())),
    );
    final container = ProviderContainer.test(
      overrides: [downloadManagerProvider.overrideWithValue(manager)],
    );
    manager.submit(downloadRequest(1));
    await _pumpPage(tester, container);
    await tester.tap(find.widgetWithText(TextButton, '管理'));
    await tester.pump();
    await tester.tap(find.byIcon(UiIcons.selectAll));
    await tester.pump();
    await tester.tap(find.byIcon(UiIcons.cancelCircle));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, '取消'));
    await tester.pump();
    expect(manager.waiting, 1, reason: 'the batch waits on its cancel');

    await tester.pumpWidget(const SizedBox());
    manager.cancels.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  group('row tap, clear completed and undo', () {
    List<ScriptedResponse> done(int count) => [
      for (var i = 0; i < count; i++)
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [i],
          ],
        ),
    ];

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
      // A named entry in the overflow, not a bare icon.
      final clear = find.widgetWithText(MenuItemButton, '清除已完成');
      Future<void> toggleMenu() async {
        await tester.tap(find.byIcon(UiIcons.more));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await _pumpPage(tester, container);
      await pumpUntil(
        tester,
        () => manager.tasks.every((t) => isTerminal(t.status)),
      );
      await tester.pump();
      final order = [for (final task in manager.tasks) task.id];

      await toggleMenu();
      await tester.tap(clear);
      // The menu closes, then the rows play their exit.
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(manager.tasks.single.status, DownloadStatus.failed);
      expect(find.text('已移除 2 条记录'), findsOneWidget);
      // Only failures left: nothing to clear.
      await toggleMenu();
      expect(tester.widget<MenuItemButton>(clear).onPressed, isNull);
      await toggleMenu();

      await _tapUndo(tester);
      await tester.pump();
      expect([for (final task in manager.tasks) task.id], order);
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
      await _pumpPage(tester, container);
      await pumpUntil(
        tester,
        () => manager.tasks.every((t) => t.status == DownloadStatus.succeeded),
      );
      await tester.pump();

      await tester.tap(
        find.descendant(
          of: _groupHeader(group.id),
          matching: find.byIcon(UiIcons.removeCircle),
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

    testWidgets(
      'failed/canceled group header offers retry and remove with undo; retryable error group offers retry and cancel',
      (tester) async {
        Finder iconIn(Finder parent, IconData icon) =>
            find.descendant(of: parent, matching: find.byIcon(icon));

        // 1. Failed group header: Retry + Remove Record (with Undo), never Cancel.
        final (failedContainer, failedManager, _) = await makeDownloadWorld(
          responses: [
            for (var i = 1; i <= 2; i++)
              ScriptedResponse(
                contentLength: 1,
                chunks: [
                  [i],
                ],
                error: StateError('boom-$i'),
              ),
          ],
        );
        final failedGroup = failedManager.submitGroup([
          downloadRequest(1),
          downloadRequest(2),
        ]);
        await _pumpPage(tester, failedContainer);
        await pumpUntil(
          tester,
          () => failedManager.tasks.every(
            (t) => t.status == DownloadStatus.failed,
          ),
        );
        await tester.pump();

        final failedHeader = _groupHeader(failedGroup.id);
        expect(iconIn(failedHeader, UiIcons.refresh), findsOneWidget);
        expect(iconIn(failedHeader, UiIcons.removeCircle), findsOneWidget);
        expect(iconIn(failedHeader, UiIcons.close), findsNothing);
        await tester.tap(iconIn(failedHeader, UiIcons.removeCircle));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(failedManager.groups, isEmpty);
        await _tapUndo(tester);
        await tester.pump();
        await tester.pump();
        expect(failedManager.groups.single.id, failedGroup.id);

        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        // 2. Non-paused retryable group (interrupted across restart) shows
        //    Retry instead of paused Resume, while keeping Cancel; canceling
        //    transitions its secondary action to Remove.
        final store = MemoryDownloadRecoveryStore();
        for (final id in const [3, 4]) {
          final request = downloadRequest(id);
          await store.upsert(
            DownloadRecoveryRecord(
              jobId: 'job-r-$id',
              dedupeKey: request.dedupeKey,
              snapshot: DownloadSubmissionSnapshot(
                snapshotId: 'sub-r-$id',
                jobId: 'job-r-$id',
                groupId: 'group-r',
                request: request,
                accountId: 'account-a',
                submittedAt: DateTime.utc(2026, 9, 30),
              ),
              owner: DownloadOutputOwner(
                ownerId: 'out-r-$id',
                jobId: 'job-r-$id',
                accountId: 'account-a',
              ),
              status: DownloadStatus.running,
            ),
          );
        }
        final retryManager = DownloadManager(
          transport: FakeTransport(),
          sinkFactory: MemorySinkFactory(),
          submissionContext: () =>
              const DownloadSubmissionContext(accountId: 'account-a'),
          recoveryStore: store,
        );
        await retryManager.recover();
        final retryContainer = ProviderContainer.test(
          overrides: [downloadManagerProvider.overrideWithValue(retryManager)],
        );
        await _pumpPage(tester, retryContainer);
        await tester.pump();

        final retryHeader = _groupHeader('group-r');
        expect(iconIn(retryHeader, UiIcons.refresh), findsOneWidget);
        expect(iconIn(retryHeader, UiIcons.play), findsNothing);
        expect(iconIn(retryHeader, UiIcons.close), findsOneWidget);

        await tester.tap(iconIn(retryHeader, UiIcons.close));
        await pumpUntil(
          tester,
          () => retryManager.tasks.every(
            (t) => t.status == DownloadStatus.canceled,
          ),
        );
        await tester.pump();
        expect(iconIn(retryHeader, UiIcons.removeCircle), findsOneWidget);
      },
    );

    testWidgets(
      'desktop succeeded row opens file, reveals in folder with bookmark, and surfaces missing file',
      (tester) async {
        const bookmark =
            'Ym9vawAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
        final calls = <(String, String, String?)>[];
        var nextResult = DesktopFileActionResult.opened;
        final fakeActions = _RecordingDesktopFileActions(
          onCall: (op, path, bm) {
            calls.add((op, path, bm));
            return nextResult;
          },
        );
        final sinkFactory = _FileUriMemorySinkFactory();
        final manager = DownloadManager(
          transport: FakeTransport()..responses.addAll(done(1)),
          sinkFactory: sinkFactory,
          enforceDefaultDestination: false,
          submissionContext: () => const DownloadSubmissionContext(
            accountId: 'a',
            destination: DownloadDestination.safFolder(bookmark),
          ),
        );
        final container = ProviderContainer.test(
          overrides: [
            downloadManagerProvider.overrideWithValue(manager),
            platformCapsProvider.overrideWithValue(
              const PlatformCaps(isMacOS: true),
            ),
            downloadDestinationProvider.overrideWithValue(
              const DownloadDestination.safFolder(bookmark),
            ),
            desktopFileActionsProvider.overrideWithValue(fakeActions),
          ],
        );
        final task = manager.submit(downloadRequest(9));
        await _pumpPage(tester, container);
        await pumpUntil(
          tester,
          () => manager.tasks.single.status == DownloadStatus.succeeded,
        );
        await tester.pump();

        final row = _taskRow(task.id);
        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byIcon(AppIcons.externalLink),
          ),
        );
        await tester.pump();
        await tester.tap(
          find.descendant(of: row, matching: find.byIcon(AppIcons.folderOpen)),
        );
        await tester.pump();
        expect(calls, [
          ('openFile', '/tmp/9_p0.jpg', bookmark),
          ('showInFolder', '/tmp/9_p0.jpg', bookmark),
        ]);

        nextResult = DesktopFileActionResult.notFound;
        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byIcon(AppIcons.externalLink),
          ),
        );
        await tester.pump();
        expect(find.text('文件已不存在'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });
}

class _RecordingDesktopFileActions implements DesktopFileActions {
  _RecordingDesktopFileActions({required this.onCall});

  final DesktopFileActionResult Function(
    String op,
    String path,
    String? bookmark,
  )
  onCall;

  @override
  Future<DesktopFileActionResult> openFile(
    String path, {
    String? macosBookmark,
  }) async => onCall('openFile', path, macosBookmark);

  @override
  Future<DesktopFileActionResult> showInFolder(
    String path, {
    String? macosBookmark,
  }) async => onCall('showInFolder', path, macosBookmark);
}

class _FileUriMemorySinkFactory extends MemorySinkFactory {
  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) async {
    final inner = await super.begin(
      request,
      displayName,
      destination: destination,
    );
    return _FileUriDownloadSink(
      inner,
      Uri.file('/tmp/$displayName').toString(),
    );
  }
}

class _FileUriDownloadSink implements DownloadSink {
  _FileUriDownloadSink(this._inner, this._uri);

  final DownloadSink _inner;
  final String _uri;

  @override
  Future<void> write(List<int> chunk) => _inner.write(chunk);

  @override
  Future<String> finalize() async {
    await _inner.finalize();
    return _uri;
  }

  @override
  Future<void> abort() => _inner.abort();
}
