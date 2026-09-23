import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
    // A canceled group still offers resume — retry accepts canceled work.
    expect(
      find.descendant(of: groupCard, matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
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
    expect(
      find.descendant(
        of: groupCard,
        matching: find.byIcon(Icons.check_circle_outline),
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
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.refresh)),
      findsOneWidget,
    );

    // Retry re-runs to success; cancel would have deleted preserved bytes.
    await tester.tap(
      find.descendant(of: tile, matching: find.byIcon(Icons.refresh)),
    );
    await _drain(
      tester,
      () => manager.tasks.single.status == DownloadStatus.succeeded,
    );
  });
}
