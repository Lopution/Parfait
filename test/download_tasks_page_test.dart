import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/motion/state_icon_switcher.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/core/download/pixiv_download_transport.dart';
import 'package:parfait/features/settings/pages/download_task_presentation.dart';
import 'package:parfait/features/settings/pages/download_tasks_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/download_world.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/test_preferences.dart';

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
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
  await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
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

  testWidgets('the developer note about DownloadManager is gone', (
    tester,
  ) async {
    final (container, manager, _) = await makeDownloadWorld(
      responses: [
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
        ),
      ],
    );
    manager.submit(downloadRequest(1));
    await _pumpPage(tester, container);
    await pumpUntil(tester, () => manager.tasks.isNotEmpty);

    // R4: the live-list header was an implementation note, not UI copy.
    expect(find.textContaining('DownloadManager'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a finished group shows the aggregate counter exactly once', (
    tester,
  ) async {
    final (container, manager, _) = await makeDownloadWorld(
      responses: [
        ScriptedResponse(
          contentLength: 3,
          chunks: [
            [1, 2, 3],
          ],
        ),
        ScriptedResponse(
          contentLength: 3,
          chunks: [
            [4, 5, 6],
          ],
        ),
      ],
    );
    final group = manager.submitGroup([downloadRequest(1), downloadRequest(2)]);
    await _pumpPage(tester, container);
    await pumpUntil(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.succeeded),
    );
    await tester.pump();

    final header = _groupHeader(group.id);
    // The header's status line IS the counter — the old card printed
    // 已完成 on both the status row and the counter row (R4).
    expect(find.text('已完成 2/2'), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
    expect(
      find.descendant(
        of: header,
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNothing,
      reason: 'a finished group shows no progress bar (R2)',
    );
    // A finished group offers 查看 (opens the first succeeded work) and
    // 移除 (dismisses every terminal child).
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.open_in_new)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: header,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a completed task hides the progress bar', (tester) async {
    final (container, manager, _) = await makeDownloadWorld(
      responses: [
        // No contentLength: completion used to force a fake 100% bar;
        // finished rows show none at all (R2).
        ScriptedResponse(
          chunks: const [
            <int>[1, 2, 3],
          ],
        ),
      ],
    );
    final task = manager.submit(downloadRequest(1));
    await _pumpPage(tester, container);
    await pumpUntil(
      tester,
      () => manager.tasks.single.status == DownloadStatus.succeeded,
    );
    await tester.pump();

    final row = _taskRow(task.id);
    expect(
      find.descendant(of: row, matching: find.byType(LinearProgressIndicator)),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('已完成')),
      findsOneWidget,
    );
    // The row still reports the finished size.
    expect(
      find.descendant(of: row, matching: find.textContaining('3 B')),
      findsOneWidget,
    );
  });

  testWidgets('paused row shows paused status with retry and cancel', (
    tester,
  ) async {
    final gate = Completer<void>();
    final (container, manager, _) = await makeDownloadWorld(
      maxConcurrent: 1,
      responses: [
        gatedResponse(gate, byte: 1),
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [9],
          ],
        ),
      ],
    );
    final task = manager.submit(downloadRequest(1));
    await _pumpPage(tester, container);
    await pumpUntil(
      tester,
      () => manager.tasks.single.status == DownloadStatus.running,
    );

    final row = _taskRow(task.id);
    await tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.pause)),
    );
    gate.complete();
    await pumpUntil(
      tester,
      () => manager.tasks.single.status == DownloadStatus.retryable,
    );
    await tester.pump();
    expect(
      find.descendant(of: row, matching: find.text('已暂停')),
      findsOneWidget,
    );
    // Paused → 继续 (resume anchor), not the retry glyph.
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.refresh)),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.byType(LinearProgressIndicator)),
      findsNothing,
      reason: 'a paused row has no progress bar (R2)',
    );
    // C8/D1: paused is not a failure — no reason line, no details
    // disclosure, no raw error.
    expect(find.descendant(of: row, matching: find.text('详情')), findsNothing);

    // Resume re-runs to success; cancel would have deleted preserved
    // bytes.
    await tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.play_arrow)),
    );
    await pumpUntil(
      tester,
      () => manager.tasks.single.status == DownloadStatus.succeeded,
    );
  });

  testWidgets('succeeded row offers view and remove', (tester) async {
    final (container, manager, _) = await makeDownloadWorld(
      responses: [
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
        ),
      ],
    );
    final task = manager.submit(downloadRequest(1));
    await _pumpPage(tester, container);
    await pumpUntil(
      tester,
      () => manager.tasks.single.status == DownloadStatus.succeeded,
    );

    final row = _taskRow(task.id);
    expect(
      find.descendant(of: row, matching: find.textContaining('已完成')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byType(LinearProgressIndicator)),
      findsNothing,
      reason: 'a finished row has no progress bar (R2)',
    );
    // 查看 + 移除 — no retry affordance on a finished task.
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.open_in_new)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.refresh)),
      findsNothing,
    );

    // Remove dismisses the terminal record.
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
    );
    await tester.pump();
    // The row's exit plays before the record drops.
    expect(manager.tasks, hasLength(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(manager.tasks, isEmpty);
    await tester.pump();
    expect(find.text('暂无下载任务'), findsOneWidget);

    // Undo puts the record and its row back.
    await _tapUndo(tester);
    await tester.pump();
    await tester.pump();
    expect(manager.taskById(task.id), isNotNull);
    expect(_taskRow(task.id), findsOneWidget);
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

  testWidgets('failed rows name the localized reason for each kind', (
    tester,
  ) async {
    // C8/D1 (design §2.4 第 4 类): the pipeline classifies each failure
    // into a DownloadFailureKind and the row shows the matching localized
    // reason instead of the raw error.
    final url = Uri.parse('https://i.pximg.net/x.jpg');
    final cases = <(Object, String)>[
      (DownloadHttpStatusException(401, url), '需要重新登录'), // auth
      (DownloadHttpStatusException(429, url), '请求过于频繁，请稍后重试'), // rateLimit
      (const SocketException('down'), '网络连接失败'), // network
      (const FileSystemException('io'), '存储错误'), // storage
      (const FormatException('bad'), '响应无法解析'), // decode
      (const DownloadPermissionException('denied'), '缺少存储权限'),
      (const DownloadResourceLimitException('too big'), '设备资源不足或文件过大'),
      (StateError('boom'), '未知错误'), // unknown
    ];
    final (container, manager, _) = await makeDownloadWorld(
      responses: [
        for (final (error, _) in cases)
          ScriptedResponse(
            contentLength: 1,
            chunks: [
              [1],
            ],
            error: error,
          ),
      ],
    );
    final tasks = [
      for (var i = 0; i < cases.length; i++)
        manager.submit(downloadRequest(100 + i)),
    ];
    await _pumpPage(tester, container);
    await pumpUntil(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.failed),
    );
    await tester.pump();

    for (var i = 0; i < cases.length; i++) {
      final row = _taskRow(tasks[i].id);
      // Rows are lazily built — scroll each one into view first.
      await tester.ensureVisible(row);
      await tester.pump();
      expect(
        find.descendant(of: row, matching: find.textContaining(cases[i].$2)),
        findsOneWidget,
        reason: 'task ${tasks[i].id} should show "${cases[i].$2}"',
      );
      // The raw error never lands in the status line; it stays behind
      // the details disclosure (ownership/canceled/paused are covered by
      // the presenter mapping and the dedicated tests).
      expect(
        find.descendant(of: row, matching: find.text('详情')),
        findsOneWidget,
        reason: 'task ${tasks[i].id} keeps its details disclosure',
      );
    }
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

  testWidgets('a failed child in an expanded group shows reason and details', (
    tester,
  ) async {
    final (container, manager, _) = await makeDownloadWorld(
      responses: [
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
          error: const DownloadPermissionException('denied'),
        ),
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [2],
          ],
        ),
      ],
    );
    final group = manager.submitGroup([downloadRequest(1), downloadRequest(2)]);
    await _pumpPage(tester, container);
    await pumpUntil(
      tester,
      () => manager.tasks.every(
        (t) =>
            t.status == DownloadStatus.failed ||
            t.status == DownloadStatus.succeeded,
      ),
    );
    await tester.pump();

    final header = _groupHeader(group.id);
    // Collapsed: children (and their failure details) stay out of the list.
    expect(_taskRows(skipOffstage: false), findsNothing);

    await tester.tap(header);
    await tester.pumpAndSettle();

    final failed = manager.tasks.firstWhere(
      (t) => t.status == DownloadStatus.failed,
    );
    final row = _taskRow(failed.id);
    await tester.ensureVisible(row);
    await tester.pump();
    expect(
      find.descendant(of: row, matching: find.textContaining('缺少存储权限')),
      findsOneWidget,
    );
    final detailsButton = find.descendant(of: row, matching: find.text('详情'));
    expect(detailsButton, findsOneWidget);
    await tester.ensureVisible(detailsButton);
    await tester.tap(detailsButton);
    await tester.pump();
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('DownloadPermissionException'),
      ),
      findsOneWidget,
      reason: 'the raw error stays reachable behind 详情 (R6)',
    );
  });

  testWidgets('progress bars render only while a row is unfinished', (
    tester,
  ) async {
    final gateKnown = Completer<void>();
    final gateUnknown = Completer<void>();
    // Concurrency 2 keeps the last submission genuinely queued: t3 and
    // t4 fill the slots after t1/t2 settle, and t5 never gets one.
    final (container, manager, _) = await makeDownloadWorld(
      maxConcurrent: 2,
      responses: [
        // t1 succeeds, t2 fails, t3 runs with a known total, t4 runs
        // without one, t5 stays queued and is cancelled.
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
        ),
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
          error: StateError('boom'),
        ),
        gatedResponse(gateKnown),
        ScriptedResponse(
          chunks: const [
            <int>[1],
          ],
          completers: [gateUnknown],
        ),
      ],
    );
    final succeeded = manager.submit(downloadRequest(1));
    final failed = manager.submit(downloadRequest(2));
    final running = manager.submit(downloadRequest(3));
    final unknown = manager.submit(downloadRequest(4));
    final queued = manager.submit(downloadRequest(5));
    await _pumpPage(tester, container);
    // Both late submissions running means t1 succeeded and t2 failed.
    await pumpUntil(
      tester,
      () =>
          manager.taskById(unknown.id)!.status == DownloadStatus.running &&
          manager.taskById(running.id)!.status == DownloadStatus.running &&
          manager.taskById(queued.id)!.status == DownloadStatus.queued,
    );
    await manager.cancel(queued.id);
    await tester.pump();

    // Running rows keep a bar: known total is determinate, unknown is not.
    final runningBar = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: _taskRow(running.id),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(runningBar.value, 0.0);
    final unknownBar = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: _taskRow(unknown.id),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(unknownBar.value, isNull);

    // Terminal rows show none.
    for (final task in [succeeded, failed, queued]) {
      expect(
        find.descendant(
          of: _taskRow(task.id),
          matching: find.byType(LinearProgressIndicator),
        ),
        findsNothing,
        reason: '${task.id} is terminal and must not show a bar',
      );
    }
    expect(
      find.descendant(
        of: _taskRow(queued.id),
        matching: find.textContaining('已取消'),
      ),
      findsOneWidget,
    );

    // Pausing the running task drops its bar too.
    await tester.tap(
      find.descendant(
        of: _taskRow(running.id),
        matching: find.byIcon(Icons.pause),
      ),
    );
    gateKnown.complete();
    await pumpUntil(
      tester,
      () => manager.taskById(running.id)!.status == DownloadStatus.retryable,
    );
    await tester.pump();
    expect(
      find.descendant(
        of: _taskRow(running.id),
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNothing,
    );
  });

  testWidgets('task rows render the page thumbnail or a placeholder', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      // The gated first task stays running forever — an uncompleted
      // completer blocks on a future and leaves no pending timer behind.
      final (container, manager, _) = await makeDownloadWorld(
        maxConcurrent: 1,
        responses: [gatedResponse(Completer<void>())],
      );
      final withThumb = manager.submit(
        downloadRequest(1, thumbnailUrl: 'https://i.pximg.net/1/s.jpg'),
      );
      final withoutThumb = manager.submit(downloadRequest(2));
      await _pumpPage(tester, container);
      await pumpUntil(tester, () => manager.tasks.isNotEmpty);

      final image = tester.widget<PixivImage>(
        find.descendant(
          of: _taskRow(withThumb.id),
          matching: find.byType(PixivImage),
        ),
      );
      expect(image.url, 'https://i.pximg.net/1/s.jpg');
      expect(
        find.descendant(
          of: _taskRow(withoutThumb.id),
          matching: find.byType(PixivImage),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: _taskRow(withoutThumb.id),
          matching: find.byIcon(Icons.image_outlined),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('row title is the work name with page label and artist', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      final (container, manager, _) = await makeDownloadWorld(
        maxConcurrent: 1,
        responses: [gatedResponse(Completer<void>())],
      );
      final titled = manager.submit(
        downloadRequest(
          7,
          title: '星空',
          artist: '画师',
          pageIndex: 1,
          totalPages: 3,
        ),
      );
      final untitled = manager.submit(downloadRequest(8));
      await _pumpPage(tester, container);
      await pumpUntil(tester, () => manager.tasks.isNotEmpty);

      final titledRow = _taskRow(titled.id);
      expect(
        find.descendant(of: titledRow, matching: find.text('星空')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: titledRow, matching: find.text('第 2/3 页')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: titledRow, matching: find.text('画师')),
        findsOneWidget,
      );

      // No title carried — the row falls back to the file name.
      expect(
        find.descendant(
          of: _taskRow(untitled.id),
          matching: find.text('8_p0.jpg'),
        ),
        findsOneWidget,
      );
    });
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

    // Tap the header title to expand: children appear inside the same
    // container — their rects stay within the header's horizontal bounds
    // and they share its surface color.
    await tester.tap(find.text('批量下载 · 2 项'));
    await tester.pump();
    // The children grow in from zero height, then sit at full size.
    final firstChild = _taskRow(manager.tasks.first.id);
    expect(tester.getSize(firstChild).height, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSize(firstChild).height, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 300));
    final fullHeight = tester.getSize(firstChild).height;
    expect(_taskRows(), findsNWidgets(2));
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.expand_less)),
      findsOneWidget,
    );
    final headerRect = tester.getRect(header);
    final surface = Theme.of(
      tester.element(header),
    ).colorScheme.surfaceContainer;
    for (final task in manager.tasks) {
      final child = _taskRow(task.id);
      final childRect = tester.getRect(child);
      expect(childRect.left, greaterThanOrEqualTo(headerRect.left));
      expect(childRect.right, lessThanOrEqualTo(headerRect.right));
      expect(
        find.descendant(
          of: child,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).color == surface,
          ),
        ),
        findsOneWidget,
        reason: 'children share the group container surface',
      );
    }

    // Tap again to collapse: the children fold away, then leave the list.
    await tester.tap(find.text('批量下载 · 2 项'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSize(firstChild).height, inExclusiveRange(0, fullHeight));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_taskRows(skipOffstage: false), findsNothing);
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.expand_more)),
      findsOneWidget,
    );
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

    // ListView.builder only realizes the viewport plus its cache extent —
    // far below the full 500. >0 guards against a degenerate "no keyed
    // rows at all" pass (the eager ListView had none).
    expect(
      _taskRows(skipOffstage: false).evaluate().length,
      inInclusiveRange(1, 20),
    );
  });

  testWidgets('expanding a three-hundred-item group stays lazy', (
    tester,
  ) async {
    final (container, manager, _) = await makeDownloadWorld(
      maxConcurrent: 1,
      responses: [gatedResponse(Completer<void>())],
    );
    final group = manager.submitGroup([
      for (var i = 0; i < 300; i++) downloadRequest(i + 1),
    ]);
    await _pumpPage(tester, container);
    await pumpUntil(tester, () => manager.tasks.isNotEmpty);
    await tester.pump();

    await tester.tap(find.byKey(ValueKey('download-group-${group.id}')));
    await tester.pump();
    // The first frame also holds the growing rows at zero height; only
    // about a screen of them grows, not all 300.
    expect(
      _taskRows(skipOffstage: false).evaluate().length,
      inInclusiveRange(1, 40),
    );
    await tester.pump(const Duration(milliseconds: 300));
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
      ScaffoldMessenger.of(
        tester.element(find.byType(DownloadTasksPage)),
      ).removeCurrentSnackBar();
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

  testWidgets('list caps at the management content width', (tester) async {
    final (container, manager, _) = await makeDownloadWorld(
      responses: [
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
        ),
      ],
    );
    manager.submit(downloadRequest(1));
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpPage(tester, container);
    await pumpUntil(tester, () => manager.tasks.isNotEmpty);
    await tester.pump();

    final listRect = tester.getRect(find.byType(ListView));
    expect(listRect.width, 840);
    expect(listRect.left, (1200 - 840) / 2);
    // Let the completed download's stream drain finish before teardown.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'narrow download row stacks long names and keeps actions usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final gate = Completer<void>();
      final longTitle = List.filled(80, '长').join();
      final (container, manager, _) = await makeDownloadWorld(
        maxConcurrent: 1,
        responses: [
          gatedResponse(gate),
          ScriptedResponse(
            contentLength: 1,
            chunks: [
              [2],
            ],
          ),
        ],
      );
      final group = manager.submitGroup([
        downloadRequest(
          42,
          title: longTitle,
          namingRule: const NamingRule(preset: NamingPreset.titleId),
        ),
        downloadRequest(43),
      ]);
      await _pumpPage(tester, container);
      await pumpUntil(
        tester,
        () => manager.tasks.first.status == DownloadStatus.running,
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      final header = _groupHeader(group.id);
      // A compact group row keeps the first action plus the overflow menu.
      expect(
        find.descendant(of: header, matching: find.byIcon(Icons.more_vert)),
        findsOneWidget,
      );

      // Expand and the long-titled running child keeps the same compact
      // contract: two-line title, actions on the second line.
      await tester.tap(find.text('批量下载 · 2 项'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final longNameTask = manager.tasks.first;
      final childRow = _taskRow(longNameTask.id);
      expect(
        find.descendant(of: childRow, matching: find.byIcon(Icons.more_vert)),
        findsOneWidget,
      );
      final taskTitle = tester.widget<Text>(
        find.descendant(of: childRow, matching: find.text(longTitle)),
      );
      expect(taskTitle.maxLines, 2);
      expect(taskTitle.overflow, TextOverflow.ellipsis);
      expect(find.byTooltip('暂停'), findsNWidgets(2));
      await tester.tap(
        find.descendant(
          of: childRow,
          matching: find.byTooltip(
            MaterialLocalizations.of(
              tester.element(find.byType(DownloadTasksPage)),
            ).showMenuTooltip,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('取消'), findsOneWidget);
      // Dismiss the menu before the teardown pump.
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();

      gate.complete();
      await pumpUntil(
        tester,
        () => manager.tasks.every(
          (task) => task.status == DownloadStatus.succeeded,
        ),
      );
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

    testWidgets('clearing a whole group plays its header out too', (
      tester,
    ) async {
      final (container, manager, _) = await makeDownloadWorld(
        responses: done(2),
      );
      final group = manager.submitGroup([
        downloadRequest(1),
        downloadRequest(2),
      ]);
      double headerOpacity() => tester
          .widget<FadeTransition>(
            find
                .descendant(
                  of: _groupHeader(group.id),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value;
      await mockNetworkImagesFor(() async {
        await _pumpPage(tester, container);
        await pumpUntil(
          tester,
          () =>
              manager.tasks.every((t) => t.status == DownloadStatus.succeeded),
        );
        await tester.pump();
        expect(headerOpacity(), 1);

        await tester.tap(find.byTooltip('清除已完成'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        // The header leaves with its rows, before the records drop.
        expect(manager.groups, hasLength(1));
        expect(headerOpacity(), lessThan(1));

        await tester.pump(const Duration(milliseconds: 300));
        expect(manager.groups, isEmpty);
        expect(_groupHeader(group.id), findsNothing);

        await _tapUndo(tester);
        await tester.pump();
        await tester.pump();
        expect(manager.groups.single.jobIds, group.jobIds);
        expect(headerOpacity(), 1);
      });
    });
  });
}
