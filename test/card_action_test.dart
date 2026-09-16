import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/app/widgets/card_actions/illust_card_actions.dart';
import 'package:pixiv_func/app/widgets/feed/illust_card.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/bookmark/bookmark_store.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/watchlater/watch_later_database.dart';
import 'package:pixiv_func/core/watchlater/watch_later_repository.dart';
import 'package:pixiv_func/core/watchlater/watch_later_store.dart';
import 'package:pixiv_func/features/watchlater/watchlater_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

/// HTTP transport recording bookmark calls so the card menu's bookmark
/// adapter can be verified against real wire requests.
class _BookmarkApiFixture {
  final List<Uri> posts = [];

  http.Client build() {
    return MockClient((request) async {
      // The card watches MuteStore, whose hydrate fetches the server list.
      if (request.method == 'GET' &&
          request.url.path.endsWith('/v1/mute/list')) {
        return http.Response(
          jsonEncode({
            'muted_tags': <dynamic>[],
            'muted_users': <dynamic>[],
            'mute_limit_count': 500,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      posts.add(request.url);
      return http.Response(
        jsonEncode({'message': '', 'is_success': true}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  }
}

/// In-memory repository for widget tests. sqflite_ffi runs sqlite on a
/// worker isolate, and isolate port events are starved inside the
/// testWidgets fake-async zone — the real-DB path is already covered by
/// watch_later_store_test, so the persistence boundary is faked here while
/// the sheet/dispatch code under test stays real.
class _MemoryWatchLaterRepository extends WatchLaterRepository {
  _MemoryWatchLaterRepository()
    : super(
        database: WatchLaterDatabase(
          factory: databaseFactoryFfi,
          databasePath: inMemoryDatabasePath,
        ),
      );

  final Map<String, List<WatchLaterEntry>> _rows = {};

  List<WatchLaterEntry> _account(String accountId) =>
      _rows.putIfAbsent(accountId, () => []);

  @override
  Future<List<WatchLaterEntry>> list(String accountId) async =>
      List.unmodifiable(_account(accountId));

  @override
  Future<void> add(String accountId, IllustEntity entity) async {
    final rows = _account(accountId);
    rows.removeWhere((entry) => entry.entity.id == entity.id);
    rows.insert(
      0,
      WatchLaterEntry(
        addedAt: DateTime.now().millisecondsSinceEpoch,
        entity: entity,
      ),
    );
  }

  @override
  Future<void> remove(String accountId, int illustId) async {
    _account(accountId).removeWhere((entry) => entry.entity.id == illustId);
  }

  @override
  Future<void> clear(String accountId) async => _account(accountId).clear();
}

typedef World = (
  ProviderContainer,
  _BookmarkApiFixture,
  _MemoryWatchLaterRepository,
);

Future<World> _makeWorld() async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final fixture = _BookmarkApiFixture();
  final repository = _MemoryWatchLaterRepository();

  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen in this test');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
      watchLaterRepositoryProvider.overrideWithValue(repository),
    ],
  );
  clientRef[0] = PixivHttpClient(
    client: fixture.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return (container, fixture, repository);
}

Widget _cardApp(ProviderContainer container, Widget home) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      home: Scaffold(
        body: Center(child: SizedBox(width: 300, child: home)),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.longPress(find.byType(IllustCard));
  await tester.pumpAndSettle();
}

Future<void> _tapEntry(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(ListTile, label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long-press opens the sheet with all registered actions', (
    tester,
  ) async {
    final (container, _, _) = await _makeWorld();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        _cardApp(container, IllustCard(entity: parseIllust(illustJson(7)))),
      );
      await _openSheet(tester);
    });

    final actions = container.read(illustCardActionsProvider);
    expect(actions.map((a) => a.id), [
      'bookmark',
      'download',
      'watch-later',
      'share',
    ]);
    for (final label in ['收藏', '下载', '稍后再看', '分享']) {
      expect(
        find.widgetWithText(ListTile, label),
        findsOneWidget,
        reason: 'sheet should offer "$label"',
      );
      expect(find.bySemanticsLabel(label), findsWidgets);
    }
  });

  testWidgets('watch-later action adds, then the sheet offers remove', (
    tester,
  ) async {
    final (container, _, repository) = await _makeWorld();
    final entity = parseIllust(illustJson(9));
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_cardApp(container, IllustCard(entity: entity)));
      await _openSheet(tester);
      await _tapEntry(tester, '稍后再看');
      await tester.pump();
      await tester.pump();
    });

    expect(find.text('已加入稍后再看'), findsOneWidget);
    expect((await repository.list('100')).map((e) => e.entity.id), [9]);

    await mockNetworkImagesFor(() async {
      await _openSheet(tester);
    });
    expect(find.widgetWithText(ListTile, '从稍后再看移除'), findsOneWidget);
    await mockNetworkImagesFor(() async {
      await _tapEntry(tester, '从稍后再看移除');
      await tester.pump();
      await tester.pump();
    });
    expect(await repository.list('100'), isEmpty);
  });

  testWidgets('bookmark action sends a real add request', (tester) async {
    final (container, fixture, _) = await _makeWorld();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        _cardApp(container, IllustCard(entity: parseIllust(illustJson(11)))),
      );
      await _openSheet(tester);
      await _tapEntry(tester, '收藏');
    });

    expect(fixture.posts, hasLength(1));
    expect(fixture.posts.single.path, '/v2/illust/bookmark/add');
    expect(
      container.read(
        bookmarkStoreProvider.select(
          (s) =>
              s[const BookmarkKey(BookmarkEntityType.illust, 11)]?.bookmarked,
        ),
      ),
      isTrue,
    );

    await mockNetworkImagesFor(() async {
      await _openSheet(tester);
    });
    expect(find.widgetWithText(ListTile, '取消收藏'), findsOneWidget);
  });

  testWidgets(
    'download action surfaces submission failure for an entity without '
    'original URLs',
    (tester) async {
      final (container, _, _) = await _makeWorld();
      // Multi-page work without metaPages: originalUrlAt yields nothing,
      // so downloadAll throws FormatException — the adapter must catch
      // and report instead of propagating.
      final entity = parseIllust(illustJson(13, pageCount: 3));
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          _cardApp(container, IllustCard(entity: entity)),
        );
        await _openSheet(tester);
        await _tapEntry(tester, '下载');
      });
      expect(find.textContaining('下载失败'), findsOneWidget);
    },
  );

  testWidgets('share action copies the artwork URL', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final (container, _, _) = await _makeWorld();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        _cardApp(container, IllustCard(entity: parseIllust(illustJson(15)))),
      );
      await _openSheet(tester);
      await _tapEntry(tester, '分享');
    });

    final clip = calls.where((c) => c.method == 'Clipboard.setData').single;
    expect(
      (clip.arguments as Map)['text'],
      'https://www.pixiv.net/artworks/15',
    );
    expect(find.text('链接已复制'), findsOneWidget);
  });

  testWidgets('watch-later page renders stored works and empty state', (
    tester,
  ) async {
    final (container, _, repository) = await _makeWorld();
    await repository.add('100', parseIllust(illustJson(21)));
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_cardApp(container, const WatchLaterPage()));
      await tester.pumpAndSettle();
    });
    expect(find.text('illust 21'), findsWidgets);
    expect(find.byType(IllustCard), findsOneWidget);

    await repository.remove('100', 21);
    container.invalidate(watchLaterStoreProvider);
    await mockNetworkImagesFor(() async {
      await tester.pumpAndSettle();
    });
    expect(find.text('暂存的作品会显示在这里'), findsOneWidget);
  });
}
