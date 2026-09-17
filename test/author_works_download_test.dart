import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/download/author_works_enumerator.dart';
import 'package:pixiv_func/core/download/download_manager.dart';
import 'package:pixiv_func/core/download/download_providers.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/user/user_repository.dart';
import 'package:pixiv_func/features/profile/author_works_download_dialog.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

import 'download_manager_test.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

class _FakeUserRepository implements UserRepository {
  final pages = <UserWorkType, List<UserIllustPage>>{
    UserWorkType.illust: [],
    UserWorkType.manga: [],
  };
  final calls = <(UserWorkType, String?)>[];
  CancelToken? lastToken;

  void script(UserWorkType type, List<UserIllustPage> scripted) {
    pages[type]!.addAll(scripted);
  }

  @override
  Future<UserIllustPage> fetchWorks(
    int userId, {
    required UserWorkType type,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    calls.add((type, cursor));
    lastToken = cancelToken;
    final queue = pages[type]!;
    if (queue.isEmpty) {
      throw StateError('no scripted page for $type cursor=$cursor');
    }
    return queue.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

UserIllustPage _page(List<IllustEntity> illusts, {String? next}) =>
    UserIllustPage(illusts: illusts, nextUrl: next);

IllustEntity _work(int id, {String type = 'illust', int pageCount = 1}) =>
    parseIllust(
      illustJson(
        id,
        type: type,
        pageCount: pageCount,
        withMetaPages: pageCount > 1,
        withMetaSinglePage: pageCount == 1,
      ),
    );

void main() {
  group('AuthorWorksEnumerator', () {
    test('walks illust then manga cursors and skips ugoira', () async {
      final repository = _FakeUserRepository()
        ..script(UserWorkType.illust, [
          _page([_work(1), _work(2, type: 'ugoira')], next: 'next-illust'),
          _page([_work(3)]),
        ])
        ..script(UserWorkType.manga, [
          _page([_work(4, pageCount: 3)]),
        ]);
      final progress = <int>[];

      final result = await AuthorWorksEnumerator(
        repository,
      ).enumerate(42, onProgress: progress.add);

      expect(result.truncated, isFalse);
      expect([for (final w in result.works) w.id], [1, 3, 4]);
      // Cursors chain per type; both types are enumerated.
      expect(repository.calls, [
        (UserWorkType.illust, null),
        (UserWorkType.illust, 'next-illust'),
        (UserWorkType.manga, null),
      ]);
      expect(progress, [1, 2, 3]);
    });

    test('stops at the hard cap and reports truncation', () async {
      final repository = _FakeUserRepository()
        ..script(UserWorkType.illust, [
          for (var page = 0; page < 40; page++)
            _page([
              for (var i = 0; i < 60; i++) _work(page * 60 + i + 1),
            ], next: 'cursor-$page'),
        ]);
      final result = await AuthorWorksEnumerator(repository).enumerate(7);

      expect(result.works, hasLength(AuthorWorksEnumerator.maxWorks));
      expect(result.truncated, isTrue);
    });

    test('propagates the cancel token to in-flight requests', () async {
      final repository = _FakeUserRepository()
        ..script(UserWorkType.illust, [
          _page([_work(1)]),
        ])
        ..script(UserWorkType.manga, [
          _page([_work(2)]),
        ]);
      final token = CancelToken();

      await AuthorWorksEnumerator(repository).enumerate(5, cancelToken: token);

      expect(repository.lastToken, same(token));
    });
  });

  group('AuthorWorksDownloadDialog', () {
    Future<(ProviderContainer, DownloadManager)> pumpDialog(
      WidgetTester tester,
      _FakeUserRepository repository,
    ) async {
      installMemoryPreferences();
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
        sinkFactory: MemorySinkFactory(),
      );
      final container = ProviderContainer(
        overrides: [downloadManagerProvider.overrideWithValue(manager)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: const [Locale('zh')],
            locale: const Locale('zh'),
            home: AuthorWorksDownloadDialog(
              userId: 9,
              enumerator: AuthorWorksEnumerator(repository),
            ),
          ),
        ),
      );
      await tester.pump();
      return (container, manager);
    }

    testWidgets('confirm submits one group covering every page', (
      tester,
    ) async {
      final repository = _FakeUserRepository()
        ..script(UserWorkType.illust, [
          _page([_work(1), _work(2, pageCount: 2)]),
        ])
        ..script(UserWorkType.manga, [_page(const [])]);
      final (_, manager) = await pumpDialog(tester, repository);
      await tester.pumpAndSettle();

      // 2 works, 1+2 = 3 downloadable pages.
      expect(find.textContaining('2 个作品'), findsOneWidget);
      expect(find.textContaining('3 页'), findsOneWidget);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(manager.groups, hasLength(1));
      expect(manager.groups.single.childCount, 3);
      expect(
        manager.tasks.map((t) => (t.illustId, t.pageIndex)),
        containsAll([(1, 0), (2, 0), (2, 1)]),
      );
    });

    testWidgets('empty result shows the empty state', (tester) async {
      final repository = _FakeUserRepository()
        ..script(UserWorkType.illust, [_page(const [])])
        ..script(UserWorkType.manga, [_page(const [])]);
      await pumpDialog(tester, repository);
      await tester.pumpAndSettle();

      expect(find.text('该作者没有可下载的作品。'), findsOneWidget);
    });

    testWidgets('cancel during enumeration pops without submitting', (
      tester,
    ) async {
      final repository = _FakeUserRepository()
        ..script(UserWorkType.illust, [
          _page([_work(1)]),
        ])
        ..script(UserWorkType.manga, [
          _page([_work(2)]),
        ]);
      final (_, manager) = await pumpDialog(tester, repository);

      // Cancel while still enumerating (before the first frame settles).
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(manager.groups, isEmpty);
    });
  });
}
