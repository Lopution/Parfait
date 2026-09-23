import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/haptics/app_haptics.dart';
import 'package:pixiv_func/core/download/download_manager.dart';
import 'package:pixiv_func/core/download/download_providers.dart';
import 'package:pixiv_func/core/download/download_request.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/download/download_task.dart';
import 'package:pixiv_func/features/settings/pages/download_tasks_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

import 'download_manager_test.dart';
import 'helpers/test_preferences.dart';

Future<(ProviderContainer, DownloadManager, FakeTransport)> _world({
  required List<ScriptedResponse> responses,
  int maxConcurrent = 3,
}) async {
  installMemoryPreferences();
  final transport = FakeTransport()..responses.addAll(responses);
  final manager = DownloadManager(
    transport: transport,
    sinkFactory: MemorySinkFactory(),
    maxConcurrent: maxConcurrent,
  );
  final container = ProviderContainer(
    overrides: [downloadManagerProvider.overrideWithValue(manager)],
  );
  addTearDown(container.dispose);
  return (container, manager, transport);
}

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

Future<void> _drain(
  WidgetTester tester,
  bool Function() predicate, {
  int tries = 40,
}) async {
  for (var i = 0; i < tries && !predicate(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

DownloadRequest _req(int id) => DownloadRequest(
  illustId: id,
  pageIndex: 0,
  url: Uri.parse('https://i.pximg.net/$id/p0.jpg'),
  target: DownloadTarget.illustPage,
);

ScriptedResponse _gated(Completer<void> gate, {int byte = 1}) =>
    ScriptedResponse(
      contentLength: 1,
      chunks: [
        [byte],
      ],
      completers: [gate],
    );

void main() {
  testWidgets('group card pauses, resumes and cancels children', (
    tester,
  ) async {
    final gates = [Completer<void>(), Completer<void>()];
    final resumeGates = [Completer<void>(), Completer<void>()];
    final (container, manager, transport) = await _world(
      responses: [
        _gated(gates[0], byte: 1),
        _gated(gates[1], byte: 2),
        _gated(resumeGates[0], byte: 3),
        _gated(resumeGates[1], byte: 4),
      ],
    );
    manager.submitGroup([_req(1), _req(2)]);
    await _pumpPage(tester, container);
    await _drain(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.running),
    );

    final groupCard = find.byType(Card).first;
    expect(
      find.descendant(of: groupCard, matching: find.text('批量下载 · 2 项')),
      findsOneWidget,
    );
    // Children nest indented under the group card — exactly one group
    // header plus two child cards, none duplicated at the top level.
    expect(find.byType(Card), findsNWidgets(3));
    final childRect = tester.getRect(find.byType(Card).at(1));
    expect(childRect.left, greaterThan(tester.getRect(groupCard).left));
    expect(
      find.descendant(of: groupCard, matching: find.byIcon(Icons.pause)),
      findsOneWidget,
    );

    // Pause the whole group; the running children unwind once their gated
    // chunk completes, queued children flip immediately.
    await tester.tap(
      find.descendant(of: groupCard, matching: find.byIcon(Icons.pause)),
    );
    for (final gate in gates) {
      gate.complete();
    }
    await _drain(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.retryable),
    );
    await tester.pump();
    expect(
      find.descendant(of: groupCard, matching: find.text('已暂停')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: groupCard, matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
    );

    // Resume re-submits every child; the group tracks the new job ids.
    await tester.tap(
      find.descendant(of: groupCard, matching: find.byIcon(Icons.play_arrow)),
    );
    await _drain(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.running),
    );
    expect(transport.openedUrls, hasLength(4));

    // Cancel lands every child in canceled — preserved output is dropped.
    await tester.tap(
      find.descendant(of: groupCard, matching: find.byIcon(Icons.close)),
    );
    for (final gate in resumeGates) {
      gate.complete();
    }
    await _drain(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.canceled),
    );
    await tester.pump();
    // A canceled group offers 重试 (refresh) — retry accepts canceled
    // work; 继续 (play_arrow) is reserved for the paused state.
    expect(
      find.descendant(of: groupCard, matching: find.byIcon(Icons.refresh)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: groupCard, matching: find.byIcon(Icons.play_arrow)),
      findsNothing,
    );
  });

  testWidgets('group card shows aggregate succeeded count', (tester) async {
    final (container, manager, _) = await _world(
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
    manager.submitGroup([_req(1), _req(2)]);
    await _pumpPage(tester, container);
    await _drain(
      tester,
      () => manager.tasks.every((t) => t.status == DownloadStatus.succeeded),
    );
    await tester.pump();

    final groupCard = find.byType(Card).first;
    expect(
      find.descendant(of: groupCard, matching: find.text('已完成 2/2')),
      findsOneWidget,
    );
    // A finished group offers 查看 (opens the first succeeded work) and
    // 移除 (dismisses every terminal child).
    expect(
      find.descendant(of: groupCard, matching: find.byIcon(Icons.open_in_new)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: groupCard,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
      findsOneWidget,
    );
  });

  testWidgets('paused tile shows paused status with retry and cancel', (
    tester,
  ) async {
    final gate = Completer<void>();
    final (container, manager, _) = await _world(
      maxConcurrent: 1,
      responses: [
        _gated(gate, byte: 1),
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [9],
          ],
        ),
      ],
    );
    manager.submit(_req(1));
    await _pumpPage(tester, container);
    await _drain(
      tester,
      () => manager.tasks.single.status == DownloadStatus.running,
    );

    final tile = find.byType(Card).first;
    await tester.tap(
      find.descendant(of: tile, matching: find.byIcon(Icons.pause)),
    );
    gate.complete();
    await _drain(
      tester,
      () => manager.tasks.single.status == DownloadStatus.retryable,
    );
    await tester.pump();
    expect(
      find.descendant(of: tile, matching: find.text('已暂停')),
      findsOneWidget,
    );
    // Paused → 继续 (resume anchor), not the retry glyph.
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.refresh)),
      findsNothing,
    );

    // Resume re-runs to success; cancel would have deleted preserved
    // bytes.
    await tester.tap(
      find.descendant(of: tile, matching: find.byIcon(Icons.play_arrow)),
    );
    await _drain(
      tester,
      () => manager.tasks.single.status == DownloadStatus.succeeded,
    );
  });

  testWidgets('succeeded tile offers view and remove', (tester) async {
    final (container, manager, _) = await _world(
      responses: [
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
        ),
      ],
    );
    manager.submit(_req(1));
    await _pumpPage(tester, container);
    await _drain(
      tester,
      () => manager.tasks.single.status == DownloadStatus.succeeded,
    );

    final tile = find.byType(Card).first;
    expect(
      find.descendant(of: tile, matching: find.text('已完成')),
      findsOneWidget,
    );
    // 查看 + 移除 — no retry affordance on a finished task.
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.open_in_new)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.refresh)),
      findsNothing,
    );

    // Remove dismisses the terminal record.
    await tester.tap(
      find.descendant(
        of: tile,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
    );
    await tester.pump();
    expect(manager.tasks, isEmpty);
    await tester.pump();
    expect(find.text('暂无下载任务'), findsOneWidget);
  });

  testWidgets('failed tile offers retry and remove', (tester) async {
    final (container, manager, _) = await _world(
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
    manager.submit(_req(1));
    await _pumpPage(tester, container);
    await _drain(
      tester,
      () => manager.tasks.single.status == DownloadStatus.failed,
    );

    final tile = find.byType(Card).first;
    expect(
      find.descendant(of: tile, matching: find.text('失败')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.refresh)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
      findsOneWidget,
    );

    // Remove dismisses the failed record.
    await tester.tap(
      find.descendant(
        of: tile,
        matching: find.byIcon(Icons.remove_circle_outline),
      ),
    );
    await tester.pump();
    expect(manager.tasks, isEmpty);
  });
  testWidgets(
    'selection mode batch-removes terminal and batch-cancels active',
    (tester) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        },
      );
      AppHaptics.debugReset();
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        AppHaptics.debugReset();
      });

      final gate = Completer<void>();
      final (container, manager, _) = await _world(
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
      manager.submit(_req(1));
      manager.submit(_req(2));
      await _pumpPage(tester, container);
      await _drain(
        tester,
        () =>
            manager.tasks.any((t) => t.status == DownloadStatus.succeeded) &&
            manager.tasks.any((t) => t.status == DownloadStatus.running),
      );

      // Entering selection mode fires the explicit vibration; the AppBar
      // swaps to the count surface.
      await tester.tap(find.byIcon(Icons.checklist_outlined));
      await tester.pump();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.heavyImpact']);

      // Select-all is the light tick; selected rows drop their nested
      // action row for the check affordance.
      await tester.tap(find.byIcon(Icons.select_all));
      await tester.pump();
      expect(find.text('已选 2 项'), findsOneWidget);
      expect(haptics.last, 'HapticFeedbackType.selectionClick');
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.byIcon(Icons.open_in_new), findsNothing);

      // Batch remove qualifies only the terminal task — the confirm
      // dialog opening fires the explicit vibration.
      AppHaptics.debugReset();
      haptics.clear();
      await tester.tap(find.byIcon(Icons.remove_circle_outline));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '移除'));
      await tester.pump();
      expect(manager.tasks.single.status, DownloadStatus.running);
      expect(find.text('已选 0 项'), findsNothing);
      expect(find.text('下载任务'), findsOneWidget);

      // Batch cancel on the running task also goes through the confirm
      // dialog, then the task unwinds once its gate opens.
      await tester.tap(find.byIcon(Icons.checklist_outlined));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.select_all));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.cancel_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '取消'));
      gate.complete();
      await _drain(
        tester,
        () => manager.tasks.single.status == DownloadStatus.canceled,
      );
    },
  );

  testWidgets('list caps at the management content width', (tester) async {
    final (container, manager, _) = await _world(
      responses: [
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
        ),
      ],
    );
    manager.submit(_req(1));
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpPage(tester, container);
    await _drain(tester, () => manager.tasks.isNotEmpty);
    await tester.pump();

    final listRect = tester.getRect(find.byType(ListView));
    expect(listRect.width, 840);
    expect(listRect.left, (1200 - 840) / 2);
    // Let the completed download's stream drain finish before teardown.
    await tester.pump(const Duration(seconds: 1));
  });
}
