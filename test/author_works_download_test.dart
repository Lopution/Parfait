import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/core/download/author_works_enumerator.dart';
import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_recovery.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/profile/author_works_download_dialog.dart';

import 'helpers/api_responses.dart';
import 'helpers/download_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/profile_world.dart';

/// The App API's user works, scripted per type: each request answers its
/// type's next page, chained to the one after it by `next_url`. [calls]
/// logs each request's type and offset.
class _WorksPages {
  final pages = <String, List<List<Map<String, dynamic>>>>{
    'illust': [],
    'manga': [],
  };
  final calls = <(String, String?)>[];

  /// When set, answers wait on it — a request still in flight.
  Completer<void>? gate;

  void script(String type, List<List<Map<String, dynamic>>> scripted) {
    pages[type]!.addAll(scripted);
  }

  Map<String, ApiRoute> get routes => {
    '/v1/user/illusts': (request) async {
      final query = request.url.queryParameters;
      final type = query['type']!;
      calls.add((type, query['offset']));
      await gate?.future;
      final queue = pages[type]!;
      if (queue.isEmpty) throw StateError('no scripted page for $type');
      final page = queue.removeAt(0);
      final offset = int.parse(query['offset'] ?? '0') + page.length;
      return jsonResponse({
        'illusts': page,
        'next_url': queue.isEmpty
            ? null
            : request.url
                  .replace(queryParameters: {...query, 'offset': '$offset'})
                  .toString(),
      });
    },
  };

  /// An enumerator over the app's user repository on these pages.
  Future<AuthorWorksEnumerator> enumerator() async =>
      AuthorWorksEnumerator(await userRepositoryOver(routes));
}

/// Holds caption sidecars at the sink until [gate] opens, so a submission
/// stays in flight.
class _HeldRawSinks extends MemorySinkFactory {
  final gate = Completer<void>();

  @override
  Future<DownloadSink> beginRaw({
    required String displayName,
    required String mimeType,
    required DownloadDestination destination,
    DownloadOutputOwner? owner,
  }) async {
    await gate.future;
    return super.beginRaw(
      displayName: displayName,
      mimeType: mimeType,
      destination: destination,
      owner: owner,
    );
  }
}

Map<String, dynamic> _work(
  int id, {
  String type = 'illust',
  int pageCount = 1,
}) => illustJson(
  id,
  type: type,
  pageCount: pageCount,
  withMetaPages: pageCount > 1,
  withMetaSinglePage: pageCount == 1,
);

void main() {
  group('AuthorWorksEnumerator', () {
    test('walks illust then manga cursors and skips ugoira', () async {
      final repository = _WorksPages()
        ..script('illust', [
          [_work(1), _work(2, type: 'ugoira')],
          [_work(3)],
        ])
        ..script('manga', [
          [_work(4, pageCount: 3)],
        ]);
      final progress = <int>[];

      final result = await (await repository.enumerator()).enumerate(
        42,
        onProgress: progress.add,
      );

      expect(result.truncated, isFalse);
      expect([for (final w in result.works) w.id], [1, 3, 4]);
      // Cursors chain per type; both types are enumerated.
      expect(repository.calls, [
        ('illust', null),
        ('illust', '2'),
        ('manga', null),
      ]);
      expect(progress, [1, 2, 3]);
    });

    test('stops at the hard cap and reports truncation', () async {
      final repository = _WorksPages()
        ..script('illust', [
          for (var page = 0; page < 40; page++)
            [for (var i = 0; i < 60; i++) _work(page * 60 + i + 1)],
        ]);
      final result = await (await repository.enumerator()).enumerate(7);

      expect(result.works, hasLength(AuthorWorksEnumerator.maxWorks));
      expect(result.truncated, isTrue);
    });

    test('the cancel token cancels the request in flight', () async {
      final gate = Completer<void>();
      final repository = _WorksPages()
        ..gate = gate
        ..script('illust', [
          [_work(1)],
        ]);
      final token = CancelToken();

      final enumeration = (await repository.enumerator()).enumerate(
        5,
        cancelToken: token,
      );
      await pumpEventQueue();
      token.cancel();

      await expectLater(enumeration, throwsA(isA<ApiCancelled>()));
      gate.complete();
    });
  });

  group('AuthorWorksDownloadDialog', () {
    late Future<int?> dialogResult;
    late _HeldRawSinks sinks;

    Future<(ProviderContainer, DownloadManager)> pumpDialog(
      WidgetTester tester,
      _WorksPages repository,
    ) async {
      final enumerator = await repository.enumerator();
      sinks = _HeldRawSinks();
      final manager = DownloadManager(
        transport: FakeTransport()
          ..responses.addAll([
            for (var i = 0; i < 64; i++)
              ScriptedResponse(
                contentLength: 1,
                chunks: [
                  [i],
                ],
              ),
          ]),
        sinkFactory: sinks,
        submissionContext: () =>
            const DownloadSubmissionContext(accountId: '1'),
      );
      final container = ProviderContainer.test(
        overrides: [
          downloadManagerProvider.overrideWithValue(manager),
          downloadSinkFactoryProvider.overrideWithValue(sinks),
          downloadCaptionProvider.overrideWithValue(true),
        ],
      );
      // Over a page, as the author page opens it.
      await tester.pumpWidget(
        localizedApp(container: container, home: const Text('author page')),
      );
      dialogResult = showDialog<int>(
        context: tester.element(find.text('author page')),
        builder: (_) =>
            AuthorWorksDownloadDialog(userId: 9, enumerator: enumerator),
      );
      await tester.pump();
      return (container, manager);
    }

    testWidgets('confirm submits one group covering every page', (
      tester,
    ) async {
      final repository = _WorksPages()
        ..script('illust', [
          [_work(1), _work(2, pageCount: 2)],
        ])
        ..script('manga', [[]]);
      final (_, manager) = await pumpDialog(tester, repository);
      await tester.pumpAndSettle();

      // 2 works, 1+2 = 3 downloadable pages.
      expect(find.textContaining('2 个作品'), findsOneWidget);
      expect(find.textContaining('3 页'), findsOneWidget);

      // A double tap submits once and closes only the dialog. The caption
      // write holds the first submission while the second tap lands.
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.tap(find.text('确定'), warnIfMissed: false);
      await tester.pump();
      sinks.gate.complete();
      await tester.pumpAndSettle();
      expect(await dialogResult, 3);
      expect(sinks.rawNames, hasLength(2), reason: 'one caption per work');

      expect(find.text('author page'), findsOneWidget);
      expect(manager.groups, hasLength(1));
      expect(manager.groups.single.childCount, 3);
      expect(
        manager.tasks.map((t) => (t.illustId, t.pageIndex)),
        containsAll([(1, 0), (2, 0), (2, 1)]),
      );
    });

    testWidgets('a submit that ends under another page closes the dialog', (
      tester,
    ) async {
      final repository = _WorksPages()
        ..script('illust', [
          [_work(1)],
        ])
        ..script('manga', [[]]);
      await pumpDialog(tester, repository);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pump();
      // A share opens a page over the dialog while the submission runs.
      unawaited(
        Navigator.of(
          tester.element(find.text('author page')),
        ).push(MaterialPageRoute<void>(builder: (_) => const Text('shared'))),
      );
      await tester.pumpAndSettle();
      final dialog = find.byType(
        AuthorWorksDownloadDialog,
        skipOffstage: false,
      );
      expect(find.text('shared'), findsOneWidget);
      expect(dialog, findsOneWidget, reason: 'still under the shared page');
      sinks.gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('shared'), findsOneWidget);
      expect(dialog, findsNothing);
      expect(await dialogResult, 1);
    });

    testWidgets('cancel during enumeration pops without submitting', (
      tester,
    ) async {
      final repository = _WorksPages()
        ..script('illust', [
          [_work(1)],
        ])
        ..script('manga', [
          [_work(2)],
        ]);
      final (_, manager) = await pumpDialog(tester, repository);

      // Cancel while still enumerating (before the first frame settles).
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(manager.groups, isEmpty);
    });
  });
}
