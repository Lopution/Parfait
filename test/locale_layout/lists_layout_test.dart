import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/novel_entry.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/bookmark/bookmark_repository.dart';
import 'package:parfait/core/comments/comment_repository.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/core/history/history_models.dart';
import 'package:parfait/features/bookmark/bookmark_tags_page.dart';
import 'package:parfait/features/comments/comments_page.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/features/settings/pages/download_tasks_page.dart';
import 'package:parfait/features/watchlist/watchlist_page.dart';
import 'package:parfait/l10n/app_localizations.dart';

import '../helpers/bookmark_world.dart';
import '../helpers/card_world.dart';
import '../helpers/illust_fixtures.dart';
import '../helpers/comment_world.dart';
import '../helpers/download_world.dart';
import '../helpers/fake_account.dart';
import '../helpers/history_world.dart';
import '../helpers/locale_layout.dart';
import '../helpers/test_preferences.dart';
import '../helpers/watchlist_world.dart';

Future<void> _expectSettled(
  WidgetTester tester,
  Locale locale,
  LayoutProfile profile,
) async {
  await settleLayout(tester);
  await expectPageLayoutIntact(tester, locale: locale, profile: profile);
}

FakeCommentRepository _comments() => FakeCommentRepository()
  ..rootComments = [
    sampleComment(11, replyCount: 3),
    sampleComment(12, userId: 20),
    sampleComment(13, userId: 30, content: 'a longer comment ' * 6),
  ];

void main() {
  installMemoryPreferences();

  localeLayoutMatrix('lists: download tasks', (tester, locale, profile) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    // One at a time: done, failed, running, then a queued task and group.
    final (container, manager, _) = await makeDownloadWorld(
      maxConcurrent: 1,
      responses: [
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
        ),
        ScriptedResponse(contentLength: 1, error: StateError('boom')),
        gatedResponse(gate),
      ],
    );
    for (var id = 1; id <= 4; id++) {
      manager.submit(
        downloadRequest(
          id,
          title: 'work $id',
          artist: 'author',
          pageIndex: 1,
          totalPages: 3,
        ),
      );
    }
    manager.submitGroup([downloadRequest(5), downloadRequest(6)]);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          container: container,
          home: const DownloadTasksPage(),
        ),
      );
      await pumpUntil(
        tester,
        () => manager.tasks.any((t) => t.status == DownloadStatus.running),
      );
      await _expectSettled(tester, locale, profile);

      final l10n = lookupAppLocalizations(locale);
      // The failure's details, then the management bar.
      await tester.tap(find.text(l10n.errorDetails));
      await _expectSettled(tester, locale, profile);
      await tester.tap(find.text(l10n.manage));
      await _expectSettled(tester, locale, profile);
    });
  });

  final commentPages = <String, Widget>{
    'comments': const CommentsPage(workId: 1),
    'comment replies': const CommentRepliesPage(workId: 1, rootCommentId: 11),
  };
  for (final MapEntry(key: name, value: page) in commentPages.entries) {
    localeLayoutMatrix('lists: $name', (tester, locale, profile) async {
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          overrides: [
            accountStoreProvider.overrideWith(commentsAccountStore),
            commentRepositoryProvider.overrideWithValue(_comments()),
          ],
          home: page,
        ),
      );
      await _expectSettled(tester, locale, profile);
    });
  }

  localeLayoutMatrix('lists: bookmark tags', (tester, locale, profile) async {
    final repository = RecordingBookmarkRepository()
      ..tagPage = const UserBookmarkTagPage(
        tags: [
          UserBookmarkTag(name: 'procreate', count: 5),
          UserBookmarkTag(name: 'オリジナル', count: 1234),
          UserBookmarkTag(name: 'landscape', count: 42),
        ],
        nextUrl: null,
      );
    await tester.pumpWidget(
      localeLayoutApp(
        locale: locale,
        overrides: [
          accountStoreProvider.overrideWith(StubAccountStore.new),
          bookmarkRepositoryProvider.overrideWithValue(repository),
        ],
        home: const BookmarkTagsPage(),
      ),
    );
    await _expectSettled(tester, locale, profile);
  });

  localeLayoutMatrix('lists: watchlist', (tester, locale, profile) async {
    final fixture = WatchlistFixture()
      ..mangaSeries = [
        for (var id = 1; id <= 3; id++)
          {
            'id': id,
            'title': 'Series $id',
            'user': {'id': 5, 'name': 'author'},
            'latest_content_id': 700 + id,
            'published_content_count': 12,
            'url': null,
          },
      ];
    final (container, _) = await makeWatchlistWorld(fixture: fixture);
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          container: container,
          home: const WatchlistPage(),
        ),
      );
      await _expectSettled(tester, locale, profile);
    });
  });

  localeLayoutMatrix('lists: history', (tester, locale, profile) async {
    await tester.runAsync(() async {
      final repository = await openHistoryRepository([
        for (var id = 1; id <= 4; id++)
          historyRecord(
            id,
            type: id.isEven
                ? HistoryContentType.novel
                : HistoryContentType.illust,
          ),
      ]);
      final container = await makeHistoryWorld(repository);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          container: container,
          home: const HistoryPage(),
        ),
      );
      // The first page loads on the real event loop.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
    await mockNetworkImagesFor(() => _expectSettled(tester, locale, profile));
  });

  // A three-digit rank beside the title, and every corner badge, on the
  // narrowest two-column card.
  localeLayoutMatrix('lists: ranked entries', (tester, locale, profile) async {
    final (container, _, _) = await makeCardWorld();
    final novel = NovelEntity(
      id: 9,
      title: 'a ranked novel with a long title',
      caption: '',
      user: const UserEntity(id: 8, name: 'author', account: 'author'),
      tags: const [],
      textLength: 123456,
      contentVersion: 'v9',
      paragraphs: const [],
    );
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          container: container,
          home: Scaffold(
            body: ListView(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final id in [7, 8])
                      Expanded(
                        child: IllustCard(
                          entity: parseIllust(
                            illustJson(
                              id,
                              type: 'ugoira',
                              xRestrict: 1,
                              aiType: 2,
                              pageCount: 12,
                            ),
                          ),
                          rank: 100 + id,
                        ),
                      ),
                  ],
                ),
                NovelEntry.ranking(entity: novel, rank: 128),
              ],
            ),
          ),
        ),
      );
      await _expectSettled(tester, locale, profile);
    });
  });
}
